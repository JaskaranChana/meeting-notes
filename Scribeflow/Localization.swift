import Foundation

enum AppStrings {
    enum Navigation {
        static let today = String(localized: "nav.today")
        static let library = String(localized: "nav.library")
        static let tasks = String(localized: "nav.tasks")
        static let calendar = String(localized: "nav.calendar")
        static let ask = String(localized: "nav.ask")
    }

    enum Action {
        static let done = String(localized: "action.done")
        static let cancel = String(localized: "action.cancel")
        static let save = String(localized: "action.save")
        static let close = String(localized: "action.close")
    }

    enum Screen {
        static let settings = String(localized: "screen.settings")
        static let appHealth = String(localized: "screen.app_health")
        static let impact = String(localized: "screen.impact")
    }
}
