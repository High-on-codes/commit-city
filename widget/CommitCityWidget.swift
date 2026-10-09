// Commit City widget. Add this file to a Widget Extension target in Xcode that depends on the
// CommitCity package's CityKit and CityKitUI products. It is not part of the package itself
// because WidgetKit extensions only exist inside an app bundle.
//
// The widget fetches the city.json your repo's (or profile's) Action publishes to GitHub Pages,
// so it needs no app group, no account and no token. Configure the URL by long-pressing the
// widget → Edit Widget.

import AppIntents
import CityKit
import CityKitUI
import SwiftUI
import WidgetKit

struct CityWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Commit City"
    static let description = IntentDescription("Shows a city published by the Commit City GitHub Action.")

    @Parameter(title: "city.json URL", default: "")
    var cityURL: String

    @Parameter(title: "Show", default: .city)
    var framing: FramingOption
}

enum FramingOption: String, AppEnum {
    case city, newest

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Framing"
    static let caseDisplayRepresentations: [FramingOption: DisplayRepresentation] = [
        .city: "Whole city",
        .newest: "Newest building",
    ]
}

struct CityEntry: TimelineEntry, Sendable {
    enum Content: Sendable {
        case city(City)
        case failure(String)
        case placeholder
    }

    let date: Date
    let content: Content
    let framing: FramingOption
}

struct CityProvider: AppIntentTimelineProvider {
    /// The Action republishes on push and weekly; hourly is plenty and kind to the budget.
    static let refreshInterval: TimeInterval = 60 * 60
    static let requestTimeout: TimeInterval = 15

    func placeholder(in context: Context) -> CityEntry {
        CityEntry(date: .now, content: .city(DemoCity.city()), framing: .city)
    }

    func snapshot(for configuration: CityWidgetIntent, in context: Context) async -> CityEntry {
        if context.isPreview { return placeholder(in: context) }
        return await entry(for: configuration)
    }

    func timeline(for configuration: CityWidgetIntent, in context: Context) async -> Timeline<CityEntry> {
        let entry = await entry(for: configuration)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.refreshInterval)))
    }

    private func entry(for configuration: CityWidgetIntent) async -> CityEntry {
        guard let url = URL(string: configuration.cityURL), url.scheme == "https" else {
            return CityEntry(date: .now, content: .failure("Set an https city.json URL"), framing: configuration.framing)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return CityEntry(date: .now, content: .failure("city.json unavailable"), framing: configuration.framing)
            }
            var city = try City.decode(data)
            // Decay is evaluated now, not when the Action last ran.
            city.generatedAt = max(city.generatedAt, Int64(Date.now.timeIntervalSince1970))
            return CityEntry(date: .now, content: .city(city), framing: configuration.framing)
        } catch is CancellationError {
            return CityEntry(date: .now, content: .placeholder, framing: configuration.framing)
        } catch {
            return CityEntry(date: .now, content: .failure("Could not load city"), framing: configuration.framing)
        }
    }
}

struct CityWidgetView: View {
    let entry: CityEntry

    var body: some View {
        switch entry.content {
        case let .city(city):
            BlueprintCanvas(city: city, framing: entry.framing == .newest ? .newestBuilding : .city)
                .containerBackground(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255), for: .widget)
        case let .failure(message):
            Text(message.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xDD / 255).opacity(0.6))
                .containerBackground(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255), for: .widget)
        case .placeholder:
            Color.clear.containerBackground(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255), for: .widget)
        }
    }
}

@main
struct CommitCityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CommitCity", intent: CityWidgetIntent.self, provider: CityProvider()) { entry in
            CityWidgetView(entry: entry)
        }
        .configurationDisplayName("Commit City")
        .description("Your city, or its newest building.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
