import Foundation

enum TaskTimeText {
    static func compact(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes >= 60 else {
            return String.localizedStringWithFormat(
                String(localized: "duration.compact.minutes", defaultValue: "%lldm"),
                minutes
            )
        }
        let remainder = minutes % 60
        if remainder == 0 {
            return String.localizedStringWithFormat(
                String(localized: "duration.compact.hours", defaultValue: "%lldh"),
                minutes / 60
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "duration.compact.hours_minutes", defaultValue: "%1$lldh %2$lldm"),
            minutes / 60,
            remainder
        )
    }

    static func spoken(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes >= 60 else {
            return String.localizedStringWithFormat(
                String(localized: "duration.spoken.minutes", defaultValue: "%lld minutes"),
                minutes
            )
        }
        let remainder = minutes % 60
        if remainder == 0 {
            return String.localizedStringWithFormat(
                String(localized: "duration.spoken.hours", defaultValue: "%lld hours"),
                minutes / 60
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "duration.spoken.hours_minutes", defaultValue: "%1$lld hours %2$lld minutes"),
            minutes / 60,
            remainder
        )
    }
}
