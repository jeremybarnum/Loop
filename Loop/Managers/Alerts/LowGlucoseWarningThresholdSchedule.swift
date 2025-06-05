import Foundation

public struct LowGlucoseWarningThresholdSchedule {
   public struct Item: Codable {
       let startTime: TimeInterval // seconds since midnight
       let warningLevel: Double     // mg/dL offset from suspend threshold
       
       public init(startTime: TimeInterval, warningLevel: Double) {
           self.startTime = startTime
           self.warningLevel = warningLevel
       }
   }
   
   public let items: [Item]
   
   public init(items: [Item]) {
       self.items = items.sorted { $0.startTime < $1.startTime }
   }
   
   public func warningLevel(at date: Date) -> Double {
       let calendar = Calendar.current
       let components = calendar.dateComponents([.hour, .minute], from: date)
       let secondsSinceMidnight = TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60)
       
       // Find the applicable item (last item with startTime <= current time)
       let applicableItem = items.last { $0.startTime <= secondsSinceMidnight } ?? items.last
       return applicableItem?.warningLevel ?? 70.0 // Default fallback
   }
   
   // Default schedule: 5 mg/dL during day, 10 mg/dL at night
   public static var defaultSchedule: LowGlucoseWarningThresholdSchedule {
       return LowGlucoseWarningThresholdSchedule(items: [
           Item(startTime: 0, warningLevel: 65),      // Midnight - 65 mg/dL
           Item(startTime: 6.5 * 3600, warningLevel: 75), // 6:30 AM - 75 mg/dL
           Item(startTime: 22.5 * 3600, warningLevel: 65) // 10:30 PM - 65 mg/dL
       ])
   }
}

// Make the struct Codable for JSON serialization
extension LowGlucoseWarningThresholdSchedule: Codable {}

// UserDefaults storage extension
extension UserDefaults {
   private enum Key: String {
       case warningThresholdSchedule = "com.loopkit.Loop.warningThresholdSchedule"
   }
   
   var warningThresholdSchedule: LowGlucoseWarningThresholdSchedule {
       get {
           guard let data = object(forKey: Key.warningThresholdSchedule.rawValue) as? Data,
                 let schedule = try? JSONDecoder().decode(LowGlucoseWarningThresholdSchedule.self, from: data) else {
               return .defaultSchedule
           }
           return schedule
       }
       set {
           guard let data = try? JSONEncoder().encode(newValue) else { return }
           set(data, forKey: Key.warningThresholdSchedule.rawValue)
       }
   }
}
