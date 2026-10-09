/// A README badge in the city's own visual language: hairline isometric cube, monospace label,
/// one accent. Shields-style height so it lines up with the badges next to it.
public enum Badge {
    static let height = 20.0
    /// Advance of the 11 px monospace stack, measured for SF Mono / Menlo / DejaVu Sans Mono.
    static let advance = 6.62

    public static func render(city: City, theme: Theme = .carbon) -> String {
        let label = "COMMIT CITY"
        let state: String
        if city.districts.count == 1 {
            let district = city.districts[0]
            state = DecayState.evaluate(
                lastActiveAt: district.lastCommitAt, now: city.generatedAt, finished: district.status == .finished
            ).label
        } else {
            state = "\(city.districts.count) districts"
        }
        let value = "\(Format.grouped(city.buildingCount)) buildings · \(state)"

        let iconWidth = 22.0
        let labelWidth = Double(label.count) * advance + 10
        let valueWidth = Double(value.count) * advance + 14
        let width = (iconWidth + labelWidth + valueWidth).rounded(.up)
        let divider = iconWidth + labelWidth

        // Isometric cube icon, 12 px tall, drawn as linework.
        let cx = 12.0, cy = 10.0, r = 5.0
        let dx = r * Blueprint.cos30, dy = r * 0.5
        func p(_ x: Double, _ y: Double) -> String { "\(Format.coordinate(x)) \(Format.coordinate(y))" }
        let cube = "M\(p(cx, cy - r))L\(p(cx + dx, cy - r + dy))L\(p(cx, cy))L\(p(cx - dx, cy - r + dy))Z"
            + "M\(p(cx - dx, cy - r + dy))L\(p(cx - dx, cy + dy))L\(p(cx, cy + r))L\(p(cx + dx, cy + dy))L\(p(cx + dx, cy - r + dy))"
            + "M\(p(cx, cy))L\(p(cx, cy + r))"

        let font = "ui-monospace,SFMono-Regular,Menlo,Consolas,'DejaVu Sans Mono',monospace"
        return """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(Format.coordinate(width))" height="20" viewBox="0 0 \(Format.coordinate(width)) 20" role="img" aria-label="\(Format.xmlEscaped("Commit City: \(value)"))">\
            <rect width="100%" height="100%" rx="3" fill="\(theme.background)"/>\
            <path d="\(cube)" fill="none" stroke="\(theme.accent)" stroke-width="0.9" stroke-linejoin="round"/>\
            <path d="M\(Format.coordinate(divider)) 4v12" stroke="\(theme.ink)" stroke-opacity="0.25" stroke-width="0.6"/>\
            <g font-family="\(font)" font-size="11" letter-spacing="0">\
            <text x="\(Format.coordinate(iconWidth))" y="14" fill="\(theme.ink)" fill-opacity="0.7">\(label)</text>\
            <text x="\(Format.coordinate(divider + 7))" y="14" fill="\(theme.accent)">\(Format.xmlEscaped(value))</text>\
            </g></svg>

            """
    }

    public static func markdown(imageURL: String, link: String?) -> String {
        let image = "![Commit City](\(imageURL))"
        guard let link else { return image }
        return "[\(image)](\(link))"
    }
}
