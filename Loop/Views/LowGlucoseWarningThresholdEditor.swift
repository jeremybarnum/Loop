//
//  LowGlucoseWarningThresholdEditor.swift
//  Loop
//
//  Created by Jeremy Barnum on 6/5/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit

struct LowGlucoseWarningThresholdEditor: View {
    @State private var schedule: LowGlucoseWarningThresholdSchedule
    @Environment(\.presentationMode) var presentationMode
    @State private var editingItemIndex: Int?
    @State private var isEditMode = false
    private let suspendThreshold = 80
    
    init() {
        _schedule = State(initialValue: UserDefaults.standard.warningThresholdSchedule)
    }
    
    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                 //   cancelButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if schedule.items.count > 1 {
                            editButton
                        }
                        addButton
                    }
                }
            }
    }
    
    private var content: some View {
        VStack {
            VStack {
                      Text("Warning Thresholds")
                    .font(.largeTitle)
                          .fontWeight(.bold)
                          .frame(maxWidth: .infinity, alignment: .leading)
                          .padding(.horizontal)
                          .padding(.top, 24)      // Increase this value for more space
                                .padding(.bottom, 16)
                  }
            // Description section
            VStack(alignment: .leading, spacing: 12) {
                Text("Set the level that you want Loop to treat as a low for warning purposes at different times of day. Warnings will trigger when differnt alternative predicitions including when carbs aren't absorbing fall below the specified level. Make this number equal to or less than the Glucose Safety Limit of \(suspendThreshold) to avoid excessively frequent warnings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
               /* HStack {
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "info.circle")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                }*/
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal)
            
            // Schedule items
            VStack(spacing: 1) {
                ForEach(Array(schedule.items.enumerated()), id: \.offset) { index, item in
                    HStack {
                        if isEditMode {
                            Button(action: {
                                deleteItem(at: index)
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title2)
                            }
                            .padding(.leading, 8)
                        }
                        
                        ScheduleItemRow(
                            time: item.startTime,
                            warningLevel: item.warningLevel,
                            isEditing: editingItemIndex == index,
                            onTimeChange: { newTime in
                                updateItem(at: index, startTime: newTime, warningLevel: item.warningLevel)
                            },
                            onValueChange: { newValue in
                                updateItem(at: index, startTime: item.startTime, warningLevel: newValue)
                            },
                            onTap: {
                                if !isEditMode {
                                    withAnimation {
                                        editingItemIndex = editingItemIndex == index ? nil : index
                                    }
                                }
                            }
                        )
                    }
                    
                    if index < schedule.items.count - 1 {
                        Divider()
                            .padding(.leading, isEditMode ? 50 : 16)
                    }
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(10)
            .padding()
            
            Spacer()
            
            // Save button
            Button("Save") {
                saveSchedule()
                presentationMode.wrappedValue.dismiss()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var cancelButton: some View {
        Button("Cancel") {
            presentationMode.wrappedValue.dismiss()
        }
    }
    
    private var editButton: some View {
        Button(isEditMode ? "Done" : "Edit") {
            withAnimation {
                isEditMode.toggle()
                editingItemIndex = nil
            }
        }
    }
    
    private var addButton: some View {
        Button(action: {
            addNewItem(time: 12 * 3600, value: 70)
            editingItemIndex = schedule.items.count - 1
        }) {
            Image(systemName: "plus")
        }
    }
    
    private func addNewItem(time: TimeInterval, value: Double) {
        let newItem = LowGlucoseWarningThresholdSchedule.Item(startTime: time, warningLevel: value)
        var newItems = schedule.items
        newItems.append(newItem)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
    }
    
    private func updateItem(at index: Int, startTime: TimeInterval, warningLevel: Double) {
        var newItems = schedule.items
        newItems[index] = LowGlucoseWarningThresholdSchedule.Item(startTime: startTime, warningLevel: warningLevel)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
    }
    
    private func deleteItem(at index: Int) {
        guard schedule.items.count > 1 else { return }
        var newItems = schedule.items
        newItems.remove(at: index)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
        editingItemIndex = nil
    }
    
    private func saveSchedule() {
        UserDefaults.standard.warningThresholdSchedule = schedule
    }
}

// MARK: - Schedule Item Row

struct ScheduleItemRow: View {
    let time: TimeInterval
    let warningLevel: Double
    let isEditing: Bool
    let onTimeChange: (TimeInterval) -> Void
    let onValueChange: (Double) -> Void
    let onTap: () -> Void
    
    var body: some View {
        VStack {
            HStack {
                Text(timeString)
                    .font(.body)
                    .foregroundColor(isEditing ? .blue : .primary)
                
                Spacer()
                
                Text("\(Int(warningLevel)) mg/dL")
                    .font(.body)
                    .foregroundColor(isEditing ? .blue : .primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            
            if isEditing {
                HStack {
                    DatePicker(
                        "Time",
                        selection: Binding(
                            get: { timeFromInterval(time) },
                            set: { newTime in
                                let components = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                                let newTimeInterval = TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60)
                                onTimeChange(newTimeInterval)
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    
                    Picker("Warning Level", selection: Binding(
                        get: { warningLevel },
                        set: { newValue in
                            onValueChange(newValue)
                        }
                    )) {
                        ForEach(50...100, id: \.self) { value in
                            Text("\(value) mg/dL").tag(Double(value))
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func timeFromInterval(_ interval: TimeInterval) -> Date {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return Calendar.current.date(bySettingHour: hours, minute: minutes, second: 0, of: Date()) ?? Date()
    }
    
    private var timeString: String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hours, minute: minutes, second: 0, of: Date()) ?? Date()
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - Previews

struct LowGlucoseWarningThresholdEditor_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            LowGlucoseWarningThresholdEditor()
        }
    }
}

struct ScheduleItemRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ScheduleItemRow(
                time: 8 * 3600,
                warningLevel: 65,
                isEditing: false,
                onTimeChange: { _ in },
                onValueChange: { _ in },
                onTap: { }
            )
            
            ScheduleItemRow(
                time: 16 * 3600,
                warningLevel: 70,
                isEditing: true,
                onTimeChange: { _ in },
                onValueChange: { _ in },
                onTap: { }
            )
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}
