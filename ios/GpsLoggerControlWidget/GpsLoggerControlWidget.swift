import WidgetKit
import SwiftUI

@main
struct GpsLoggerControlWidgetBundle: WidgetBundle {
    var body: some Widget {
        StartTrackingControl()
    }
}

@available(iOS 18.0, *)
struct StartTrackingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.gpslogger.personal.control-widget"
        ) {
            ControlWidgetButton(action: OpenGpsLoggerIntent()) {
                Label("Track", systemImage: "location.fill")
            }
        }
        .displayName("Track")
        .description("Opens GpsLogger to begin GPS tracking.")
    }
}
