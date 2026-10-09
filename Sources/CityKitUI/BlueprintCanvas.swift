#if canImport(SwiftUI)
    import CityKit
    import SwiftUI

    /// Draws a city with SwiftUI `Canvas` from the same `Scene` the SVG renderer uses.
    /// WidgetKit cannot render SVG, so this is how the widget shows the city.
    ///
    /// The scene and its projected bounds are computed once in `init` (off the render path);
    /// `body` only maps already-built primitives to paths.
    public struct BlueprintCanvas: View {
        public enum Framing: Sendable {
            /// The whole city, fitted.
            case city
            /// The newest building, close up, with its neighbours for context.
            case newestBuilding
        }

        private let scene: CityKit.Scene
        private let theme: Theme
        private let bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)

        public init(city: City, theme: Theme = .carbon, framing: Framing = .city, detail: DetailLevel? = nil) {
            let level = detail ?? (city.buildingCount > 600 ? .reduced : .full)
            let full = CityKit.Scene.build(city: city, at: city.generatedAt, detail: level)
            self.theme = theme
            switch framing {
            case .city:
                scene = full
            case .newestBuilding:
                scene = BlueprintCanvas.closeUp(of: city, in: full)
            }
            bounds = scene.bounds ?? (-4, -4, 4, 4)
        }

        public var body: some View {
            let theme = theme
            let scene = scene
            let bounds = bounds
            Canvas(rendersAsynchronously: true) { context, size in
                let inset = 8.0
                let worldWidth = max(1, bounds.maxX - bounds.minX)
                let worldHeight = max(1, bounds.maxY - bounds.minY)
                let scale = min((size.width - 2 * inset) / worldWidth, (size.height - 2 * inset) / worldHeight)
                let originX = (size.width - worldWidth * scale) / 2 - bounds.minX * scale
                let originY = (size.height - worldHeight * scale) / 2 - bounds.minY * scale
                func point(_ v: Vec3) -> CGPoint {
                    let p = Blueprint.project(v)
                    return CGPoint(x: originX + p.x * scale, y: originY + p.y * scale)
                }
                let background = Color(hex: theme.background)
                let ink = Color(hex: theme.ink)
                let accent = Color(hex: theme.accent)
                // Widgets are small: weights scale down gently, never below a device hairline.
                let weightScale = max(0.5, min(1, scale / 10))

                func stroke(_ path: Path, _ inkClass: Ink, _ look: BuildingLook, in context: GraphicsContext) {
                    let spec = theme.stroke(inkClass)
                    let multiplier = inkClass == .windowLit ? look.windowAlpha : look.structureAlpha
                    let decayDash = inkClass == .windowLit || inkClass == .windowDark || inkClass == .road ? nil : look.dashPattern
                    let dash = (spec.dash ?? decayDash ?? []).map { CGFloat($0 * weightScale) }
                    context.stroke(
                        path, with: .color((spec.useAccent ? accent : ink).opacity(spec.alpha * multiplier)),
                        style: StrokeStyle(
                            lineWidth: spec.width * weightScale, lineCap: .round, lineJoin: .round, dash: dash))
                }

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                for item in scene.items {
                    for primitive in item.primitives {
                        switch primitive {
                        case let .occluder(points):
                            var path = Path()
                            path.addLines(points.map(point))
                            path.closeSubpath()
                            context.fill(path, with: .color(background))
                        case let .line(points, inkClass, closed):
                            var path = Path()
                            path.addLines(points.map(point))
                            if closed { path.closeSubpath() }
                            stroke(path, inkClass, item.look, in: context)
                        case let .disc(center, radius, inkClass):
                            let c = point(center)
                            let r = max(0.6, radius * scale)
                            let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                            context.fill(path, with: .color(background))
                            stroke(path, inkClass, item.look, in: context)
                        }
                    }
                }
            }
            .accessibilityLabel(Text("City of \(scene.buildingCount) buildings"))
        }

        /// The newest building and everything standing on its block and the eight around it.
        static func closeUp(of city: City, in scene: CityKit.Scene) -> CityKit.Scene {
            var newest: (time: Int64, district: Int, building: Building)?
            for (index, district) in city.districts.enumerated() {
                for building in district.buildings where building.style != .park {
                    if newest == nil || (building.bornAt, index, building.id) > (newest!.time, newest!.district, newest!.building.id) {
                        newest = (building.bornAt, index, building)
                    }
                }
            }
            guard let newest else { return scene }
            let pitch = District.blockPitch
            let floorDiv = { (value: Int) -> Int in value >= 0 ? value / pitch : (value - pitch + 1) / pitch }
            let home = (floorDiv(newest.building.lot.x), floorDiv(newest.building.lot.y))
            let district = city.districts[newest.district]
            let nearby = Set(district.buildings.filter {
                abs(floorDiv($0.lot.x) - home.0) <= 1 && abs(floorDiv($0.lot.y) - home.1) <= 1
            }.map(\.id))
            var focused = scene
            focused.items = scene.items.filter { item in
                guard item.district == newest.district else { return false }
                guard let id = item.building else { return false }
                return nearby.contains(id)
            }
            return focused
        }
    }

    extension Color {
        /// "#RRGGBB" → sRGB colour. Invalid input renders magenta in debug so it cannot ship unnoticed.
        init(hex: String) {
            let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
                assertionFailure("invalid colour \(hex)")
                self = .pink
                return
            }
            self.init(
                .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255, opacity: 1)
        }
    }
#endif
