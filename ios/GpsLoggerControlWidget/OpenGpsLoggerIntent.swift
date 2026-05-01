import AppIntents

enum GpsLoggerTarget: String, AppEnum {
    case app

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "GpsLogger")

    static var caseDisplayRepresentations: [GpsLoggerTarget: DisplayRepresentation] = [
        .app: "GpsLogger"
    ]
}

struct OpenGpsLoggerIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open GpsLogger"

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Target")
    var target: GpsLoggerTarget

    init() {
        self.target = .app
    }
}
