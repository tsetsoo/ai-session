import Foundation

extension QuietHours {
    /// Today at `HH:MM` in `calendar`'s timezone, for a time picker. `nil` for anything but
    /// a valid 24-hour `HH:MM`.
    public static func date(fromHHMM text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: ":")
        guard text.count == 5, parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
    }

    /// `HH:MM` of `date` in `calendar`'s timezone.
    public static func hhmm(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
