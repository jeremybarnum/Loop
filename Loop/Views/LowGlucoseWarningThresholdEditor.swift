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
    @State private var showingNewEntry = false
    @State private var showingEditEntry = false
    @State private var editingIndex: Int?
    @State private var isEditMode = false
    
    init() {
        _schedule = State(initialValue: UserDefaults.standard.warningThresholdSchedule)
    }
    
    var body: some View {
        content
            .navigationBarTitle("Warning Thresholds", displayMode: .large)
            .navigationBarItems(
                leading: cancelButton,
                trailing: HStack {
                    if schedule.items.count > 1 {
                        editButton
                    }
                    addButton
                }
            )
            .sheet(isPresented: $showingNewEntry) {
                NewEntrySheet(onAdd: addNewItem)
            }
            .sheet(isPresented: $showingEditEntry) {
                if let index = editingIndex {
                    EditEntrySheet(
                        time: schedule.items[index].startTime,
                        warningLevel: schedule.items[index].warningLevel,
                        onSave: { time, level in
                            updateItem(at: index, startTime: time, warningLevel: level)
                        }
                    )
                }
            }
    }
    
    private var content: some View {
        VStack(spacing: 0) {
            // Description section
            VStack(alignment: .leading, spacing: 12) {
                Text("Set the level that you want Loop to treat as a low for warning purposes at different times of day. Warnings will trigger when predicted glucose falls below your specified level.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack {
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "info.circle")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            
            // Schedule items
            VStack(spacing: 1) {
                ForEach(schedule.items.indices, id: \.self) { index in
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
                            time: schedule.items[index].startTime,
                            warningLevel: schedule.items[index].warningLevel,
                            onTap: {
                                if !isEditMode {
                                    editingIndex = index
                                    showingEditEntry = true
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
            }
        }
    }
    
    private var addButton: some View {
        Button(action: { showingNewEntry = true }) {
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
        guard schedule.items.count > 1 else { return } // Prevent deleting the last item
        var newItems = schedule.items
        newItems.remove(at: index)
        schedule = LowGlucoseWarningThresholdSchedule(items: newItems)
    }
    
    private func saveSchedule() {
        UserDefaults.standard.warningThresholdSchedule = schedule
    }
}

struct ScheduleItemRow: View {
    let time: TimeInterval
    let warningLevel: Double
    let onTap: () -> Void
    
    public init(time: TimeInterval, warningLevel: Double, onTap: @escaping () -> Void) {
        self.time = time
        self.warningLevel = warningLevel
        self.onTap = onTap
    }
    
    var body: some View {
        HStack {
            Text(timeString)
                .font(.body)
            
            Spacer()
            
            Text("\(Int(warningLevel)) mg/dL")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

private struct NewEntrySheet: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedTime = Date()
    @State private var selectedValue: Double = 70
    
    let onAdd: (TimeInterval, Double) -> Void
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                DatePicker(
                    "Time",
                    selection: $selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(WheelDatePickerStyle())
                
                VStack {
                    Text("Warning Level: \(Int(selectedValue)) mg/dL")
                    Picker("Warning Level", selection: $selectedValue) {
                        ForEach(50...120, id: \.self) { value in
                            Text("\(value) mg/dL").tag(Double(value))
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                    .frame(height: 120)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("New Entry")
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Add") {
                    let components = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
                    let timeInterval = TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60)
                    onAdd(timeInterval, selectedValue)
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
}

private struct EditEntrySheet: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedTime: Date
    @State private var selectedValue: Double
    
    let onSave: (TimeInterval, Double) -> Void
    
    init(time: TimeInterval, warningLevel: Double, onSave: @escaping (TimeInterval, Double) -> Void) {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        _selectedTime = State(initialValue: Calendar.current.date(bySettingHour: hours, minute: minutes, second: 0, of: Date()) ?? Date())
        _selectedValue = State(initialValue: warningLevel)
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                DatePicker(
                    "Time",
                    selection: $selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(WheelDatePickerStyle())
                
                VStack {
                    Text("Warning Level: \(Int(selectedValue)) mg/dL")
                    Picker("Warning Level", selection: $selectedValue) {
                        ForEach(50...120, id: \.self) { value in
                            Text("\(value) mg/dL").tag(Double(value))
                        }
                    }
                    .pickerStyle(WheelPickerStyle())
                    .frame(height: 120)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Edit Entry")
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Save") {
                    let components = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
                    let timeInterval = TimeInterval((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60)
                    onSave(timeInterval, selectedValue)
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
}
