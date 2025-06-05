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
    
    init() {
        _schedule = State(initialValue: UserDefaults.standard.warningThresholdSchedule)
    }
    
    var body: some View {
        NavigationView {
            content
                .navigationTitle("Warning Thresholds")
                .navigationBarItems(
                    leading: cancelButton,
                    trailing: saveButton
                )
        }
    }

    private var content: some View {
        List {
            scheduleSection
            addButtonSection
        }
    }

    private var scheduleSection: some View {
        Section(footer: Text("Set the level that you want Loop to treat as a low for warning purposes at different times of day. Warnings will trigger when predicted glucose falls below your specified level.")) {
            ForEach(schedule.items.indices, id: \.self) { index in
                ScheduleItemRow(
                    time: schedule.items[index].startTime,
                    warningLevel: schedule.items[index].warningLevel,
                    onTimeChange: { newTime in
                        updateItem(at: index, startTime: newTime, warningLevel: schedule.items[index].warningLevel)
                    },
                    onValueChange: { newValue in
                        updateItem(at: index, startTime: schedule.items[index].startTime, warningLevel: newValue)
                    }
                )
            }
            .onDelete(perform: deleteItems)
        }
    }

    private var addButtonSection: some View {
        Section {
            Button("Add Time Period") {
                addNewItem()
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private var saveButton: some View {
        Button("Save") {
            saveSchedule()
            presentationMode.wrappedValue.dismiss()
        }
    }
    
    private func updateItem(at index: Int, startTime: TimeInterval, warningLevel: Double) {
        var newItems = schedule.items
        newItems[index] = LowGlucoseWarningThresholdSchedule.Item(startTime: startTime, warningLevel: warningLevel)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
    }
    
    private func deleteItems(offsets: IndexSet) {
        var newItems = schedule.items
        newItems.remove(atOffsets: offsets)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
    }
    
    private func addNewItem() {
        let newItem = LowGlucoseWarningThresholdSchedule.Item(startTime: 12 * 3600, warningLevel: 70)
        var newItems = schedule.items
        newItems.append(newItem)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
    }
    
    private func saveSchedule() {
        UserDefaults.standard.warningThresholdSchedule = schedule
    }
}

struct ScheduleItemRow: View {
    let time: TimeInterval
    let warningLevel: Double
    let onTimeChange: (TimeInterval) -> Void
    let onValueChange: (Double) -> Void
    
    @State private var showingTimePicker = false
    @State private var showingValuePicker = false
    @State private var tempTime: Date = Date()
    @State private var tempValue: Double = 70
    
    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading) {
                    Text("Time")
                    Button(timeString) {
                        setupTimePicker()
                        showingTimePicker = true
                    }
                    .foregroundColor(.blue)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("Warning Level")
                    Button("\(Int(warningLevel)) mg/dL") {
                        tempValue = warningLevel
                        showingValuePicker = true
                    }
                    .foregroundColor(.blue)
                }
            }
            
            if showingTimePicker {
                DatePicker(
                    "Time",
                    selection: $tempTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(WheelDatePickerStyle())
                .onChange(of: tempTime) { newTime in
                    let components = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                    let timeInterval = TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60)
                    onTimeChange(timeInterval)
                    showingTimePicker = false
                }
            }
            
            if showingValuePicker {
                HStack {
                    Text("Warning Level: \(Int(tempValue)) mg/dL")
                    Spacer()
                }
                Picker("Warning Level", selection: $tempValue) {
                    ForEach(50...120, id: \.self) { value in
                        Text("\(value) mg/dL").tag(Double(value))
                    }
                }
                .pickerStyle(WheelPickerStyle())
                .frame(height: 120)
                .onChange(of: tempValue) { newValue in
                    onValueChange(newValue)
                    showingValuePicker = false
                }
            }
        }
    }
    
    private func setupTimePicker() {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        tempTime = Calendar.current.date(bySettingHour: hours, minute: minutes, second: 0, of: Date()) ?? Date()
    }
    
    private var timeString: String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }
}
