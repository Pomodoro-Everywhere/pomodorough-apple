enum TaskTimeText {
    static func compact(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes >= 60 else { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    static func spoken(_ milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes >= 60 else { return "\(minutes) minutes" }
        let remainder = minutes % 60
        return remainder == 0
            ? "\(minutes / 60) hours"
            : "\(minutes / 60) hours \(remainder) minutes"
    }
}
