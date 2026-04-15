import ARKit
import SceneKit
import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore
import CoreMotion
import AVFoundation
import UIKit
import UniformTypeIdentifiers
// MARK: - 三、根视图：登录 + 管理员判断 + 菜单
// =======================================================

struct RecordRouteHomeView: View {
    @StateObject private var auth = AuthVM()
    @StateObject private var gate = ManagerGate()

    var body: some View {
        NavigationStack {
            Group {
                if auth.user == nil {
                    SignInView(auth: auth)
                } else if !gate.checked {
                    ManagerCheckingView()
                } else if gate.isManager {
                    MainMenuView(auth: auth, gate: gate)
                } else {
                    NotManagerView(auth: auth)
                }
            }
        }
        .onAppear { gate.start() }
        .onChange(of: auth.user) { _ in
            gate.start()
        }
    }
}

// 登录界面（只允许已有账号登录，不再提供注册）
struct SignInView: View {
    @ObservedObject var auth: AuthVM
    var body: some View {
        VStack(spacing: 16) {
            Text("Admin Sign In").font(.largeTitle).bold()
            VStack(alignment: .leading, spacing: 8) {
                Text("Email")
                TextField("admin@example.com", text: $auth.email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                SecureField("Password", text: $auth.password)
                    .textFieldStyle(.roundedBorder)
            }
            if let err = auth.errorText {
                Text(err).foregroundStyle(.red).font(.footnote)
            }
            HStack {
                Text("Accounts are created by an administrator in the Firebase console")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button("Sign in") { auth.signIn() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
    }
}

// 检查是否管理员时的加载页
struct ManagerCheckingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Checking admin permissions…")
                .foregroundStyle(.secondary)
        }
    }
}

// 非管理员提示页
struct NotManagerView: View {
    @ObservedObject var auth: AuthVM
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill.xmark")
                .font(.system(size: 60))
                .foregroundColor(.red)
            Text("This account is not an administrator")
                .font(.title2).bold()
            Text("Please sign in with an administrator account registered in the managers collection.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Log out") {
                auth.signOut()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
    }
}

// 首页菜单：记录路线 / 管理数据库 / 添加楼栋 / 添加房间 / 添加节点
struct MainMenuView: View {
    @ObservedObject var auth: AuthVM
    @ObservedObject var gate: ManagerGate

    @State private var showAddBuilding = false
    @State private var showAddRoom = false
    @State private var showAddNode = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RouteRecorderView()
                } label: {
                    HStack {
                        Image(systemName: "figure.walk.motion")
                        Text("Record route")
                    }
                }

                NavigationLink {
                    BuildingListView(auth: auth, gate: gate)
                } label: {
                    HStack {
                        Image(systemName: "tray.2")
                        Text("Manage the Database")
                    }
                }
            } header: {
                Text("Functions")
            }

            Section("Quick actions") {
                Button {
                    showAddBuilding = true
                } label: {
                    HStack {
                        Image(systemName: "building.2")
                        Text("Add buildings")
                    }
                }

                Button {
                    showAddRoom = true
                } label: {
                    HStack {
                        Image(systemName: "door.left.hand.open")
                        Text("Add rooms")
                    }
                }

                Button {
                    showAddNode = true
                } label: {
                    HStack {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        Text("Add nodes")
                    }
                }
            }
        }
        .navigationTitle("Manage System")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Log out") { auth.signOut() }
            }
        }
        .sheet(isPresented: $showAddBuilding) {
            NewBuildingFormView { _ in
                showAddBuilding = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAddRoom) {
            QuickAddRoomView { _ in
                showAddRoom = false
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showAddNode) {
            QuickAddNodeView { _ in
                showAddNode = false
            }
            .presentationDetents([.large])
        }
    }
}

// 楼宇列表
struct BuildingListView: View {
    @ObservedObject var auth: AuthVM
    @ObservedObject var gate: ManagerGate

    @State private var buildings: [Building] = []
    @State private var listener: ListenerRegistration?

    var filteredBuildings: [Building] { buildings }

    var body: some View {
        List {
            Section {
                ForEach(filteredBuildings, id: \.self) { b in
                    NavigationLink(b.id) {
                        BuildingDetailView(building: b, isManager: gate.isManager)
                    }
                }
            } header: {
                HStack {
                    Text("Buildings")
                    Spacer()
                    if gate.isManager { Text("admin").font(.caption).foregroundStyle(.green) }
                }
            }
        }
        .navigationTitle("Database")
        .onAppear {
            listener?.remove()
            listener = FS.listenBuildings { docs in
                self.buildings = docs.sorted { $0.id < $1.id }
            }
        }
        .onDisappear { listener?.remove() }
    }
}

// Sheet 枚举
private enum ActiveSheet: Identifiable, Equatable {
    case addRoom
    case editRoom(RoomDoc)
    case addRoute
    case editRoute(RouteDoc)
    case addNode
    case editNode(NodeDoc)

    var id: String {
        switch self {
        case .addRoom:                return "addRoom"
        case .editRoom(let r):        return "editRoom-\(r.id)"
        case .addRoute:               return "addRoute"
        case .editRoute(let rt):      return "editRoute-\(rt.id)"
        case .addNode:                return "addNode"
        case .editNode(let n):        return "editNode-\(n.id)"
        }
    }
}

// 楼宇详情：只负责显示 Building 信息 + 三个入口
struct BuildingDetailView: View {
    let building: Building
    let isManager: Bool

    @State private var code: String = ""
    @State private var name: String = ""
    @State private var savedHint: String? = nil

    var body: some View {
        List {
            Section("Building Info") {
                TextField("Code", text: $code)
                    .disabled(!isManager)
                TextField("Name", text: $name)
                    .disabled(!isManager)

                if isManager {
                    Button("Save Building") {
                        FS.saveBuilding(
                            id: building.id,
                            code: code.isEmpty ? nil : code,
                            name: name.isEmpty ? nil : name
                        ) { err in
                            savedHint = err == nil ? "Saved" : "Save failed: \(err!.localizedDescription)"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                savedHint = nil
                            }
                        }
                    }
                }

                if let savedHint {
                    Text(savedHint)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section("Dataset") {
                NavigationLink {
                    BuildingRoomsView(building: building, isManager: isManager)
                } label: {
                    HStack {
                        Image(systemName: "door.left.hand.open")
                        Text("Rooms")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    BuildingNodesView(building: building, isManager: isManager)
                } label: {
                    HStack {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        Text("Nodes")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    BuildingRoutesView(building: building, isManager: isManager)
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                        Text("Routes")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle(building.id)
        .onAppear {
            code = building.code ?? ""
            name = building.name ?? ""
        }
    }
}

// NOTE: Remaining Database UI code (Rooms/Nodes/Routes views + forms + QuickAdd views)
// is identical to your pasted version; to keep this single-file response within limits,
// it is included in the downloadable file.
//
// (For ChatGPT: we include full content in the generated file.)


// 楼栋下的 Rooms 页面
struct BuildingRoomsView: View {
    let building: Building
    let isManager: Bool

    @State private var rooms: [RoomDoc] = []
    @State private var roomListener: ListenerRegistration?

    @State private var selectedRoomFloor: Int? = nil
    @State private var sheet: ActiveSheet? = nil
    @State private var pendingDeleteRoom: RoomDoc? = nil

    private var roomFloors: [Int] {
        Array(Set(rooms.map { $0.floor })).sorted()
    }
    private var filteredRooms: [RoomDoc] {
        if let f = selectedRoomFloor { return rooms.filter { $0.floor == f } }
        return rooms
    }

    var body: some View {
        List {
            if !roomFloors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("All") { selectedRoomFloor = nil }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selectedRoomFloor == nil ? Color.blue.opacity(0.15) : Color.clear)
                            .cornerRadius(8)

                        ForEach(roomFloors, id: \.self) { f in
                            Button("F\(f)") { selectedRoomFloor = f }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedRoomFloor == f ? Color.blue.opacity(0.15) : Color.clear)
                                .cornerRadius(8)
                        }
                    }
                }
            }

            ForEach(filteredRooms, id: \.id) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.id).bold()
                        Text("\(r.profName) • \(r.department)")
                            .font(.caption)
                        Text("\(r.officeHour) • F\(r.floor)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isManager { Image(systemName: "square.and.pencil") }
                }
                .contentShape(Rectangle())
                .onTapGesture { if isManager { sheet = .editRoom(r) } }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isManager {
                        Button(role: .destructive) {
                            pendingDeleteRoom = r
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("\(building.id) · Rooms")
        .sheet(item: $sheet) { s in
            switch s {
            case .addRoom:
                RoomFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editRoom(let r):
                RoomFormView(buildingId: building.id, docId: r.id, initial: r) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .addRoute:
                RouteFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editRoute(let rt):
                RouteFormView(buildingId: building.id, docId: rt.id, initial: rt) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .addNode:
                NodeFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editNode(let n):
                NodeFormView(buildingId: building.id, docId: n.id, initial: n) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Delete Room", isPresented: Binding(
            get: { pendingDeleteRoom != nil },
            set: { if !$0 { pendingDeleteRoom = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let r = pendingDeleteRoom {
                    FS.deleteRoom(buildingId: building.id, docId: r.id)
                }
                pendingDeleteRoom = nil
            }
        } message: {
            Text("This will delete \(pendingDeleteRoom?.id ?? "")")
        }
        .onAppear {
            roomListener?.remove()
            roomListener = FS.listenRooms(buildingId: building.id) { docs in
                self.rooms = docs.sorted { $0.id < $1.id }
            }
        }
        .onDisappear {
            roomListener?.remove()
        }
        .toolbar {
            if isManager {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sheet = .addRoom
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
    }
}

// 楼栋下的 Nodes 页面
struct BuildingNodesView: View {
    let building: Building
    let isManager: Bool

    @State private var nodes: [NodeDoc] = []
    @State private var nodeListener: ListenerRegistration?

    @State private var selectedNodeFloor: Int? = nil
    @State private var sheet: ActiveSheet? = nil
    @State private var pendingDeleteNode: NodeDoc? = nil

    private var nodeFloors: [Int] {
        Array(Set(nodes.map { $0.floor })).sorted()
    }
    private var filteredNodes: [NodeDoc] {
        if let f = selectedNodeFloor { return nodes.filter { $0.floor == f } }
        return nodes
    }

    var body: some View {
        List {
            if !nodeFloors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("All") { selectedNodeFloor = nil }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selectedNodeFloor == nil ? Color.blue.opacity(0.15) : Color.clear)
                            .cornerRadius(8)

                        ForEach(nodeFloors, id: \.self) { f in
                            Button("F\(f)") { selectedNodeFloor = f }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedNodeFloor == f ? Color.blue.opacity(0.15) : Color.clear)
                                .cornerRadius(8)
                        }
                    }
                }
            }

            ForEach(filteredNodes, id: \.id) { n in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.id).bold()
                        Text("F\(n.floor)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if !n.leftNextNode.isEmpty || !n.leftRooms.isEmpty {
                            Text("← next: \(n.leftNextNode.isEmpty ? "-" : n.leftNextNode)")
                                .font(.caption2)
                            if !n.leftRooms.isEmpty {
                                Text("  rooms: \(n.leftRooms.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if !n.rightNextNode.isEmpty || !n.rightRooms.isEmpty {
                            Text("→ next: \(n.rightNextNode.isEmpty ? "-" : n.rightNextNode)")
                                .font(.caption2)
                            if !n.rightRooms.isEmpty {
                                Text("  rooms: \(n.rightRooms.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if isManager { Image(systemName: "square.and.pencil") }
                }
                .contentShape(Rectangle())
                .onTapGesture { if isManager { sheet = .editNode(n) } }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isManager {
                        Button(role: .destructive) {
                            pendingDeleteNode = n
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("\(building.id) · Nodes")
        .sheet(item: $sheet) { s in
            switch s {
            case .addRoom:
                RoomFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editRoom(let r):
                RoomFormView(buildingId: building.id, docId: r.id, initial: r) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .addRoute:
                RouteFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editRoute(let rt):
                RouteFormView(buildingId: building.id, docId: rt.id, initial: rt) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .addNode:
                NodeFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editNode(let n):
                NodeFormView(buildingId: building.id, docId: n.id, initial: n) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Delete Node", isPresented: Binding(
            get: { pendingDeleteNode != nil },
            set: { if !$0 { pendingDeleteNode = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let n = pendingDeleteNode {
                    FS.deleteNode(buildingId: building.id, docId: n.id)
                }
                pendingDeleteNode = nil
            }
        } message: {
            Text("This will delete \(pendingDeleteNode?.id ?? "")")
        }
        .onAppear {
            nodeListener?.remove()
            nodeListener = FS.listenNodes(buildingId: building.id) { docs in
                self.nodes = docs.sorted { $0.id < $1.id }
            }
        }
        .onDisappear {
            nodeListener?.remove()
        }
        .toolbar {
            if isManager {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sheet = .addNode
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
    }
}

// 楼栋下的 Routes 页面
struct BuildingRoutesView: View {
    let building: Building
    let isManager: Bool

    @State private var routes: [RouteDoc] = []
    @State private var routeListener: ListenerRegistration?

    @State private var selectedRouteFloor: Int? = nil
    @State private var sheet: ActiveSheet? = nil
    @State private var pendingDeleteRoute: RouteDoc? = nil

    private func floorFromRouteId(_ id: String) -> Int? {
        guard id.first == "F" else { return nil }
        var digits = ""
        for ch in id.dropFirst() {
            if ch.isNumber {
                digits.append(ch)
            } else {
                break
            }
        }
        return Int(digits)
    }
    private var routeFloors: [Int] {
        let fs = routes.compactMap { floorFromRouteId($0.id) }
        return Array(Set(fs)).sorted()
    }
    private var filteredRoutes: [RouteDoc] {
        if let f = selectedRouteFloor {
            return routes.filter { floorFromRouteId($0.id) == f }
        }
        return routes
    }

    var body: some View {
        List {
            if !routeFloors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("All") { selectedRouteFloor = nil }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selectedRouteFloor == nil ? Color.blue.opacity(0.15) : Color.clear)
                            .cornerRadius(8)

                        ForEach(routeFloors, id: \.self) { f in
                            Button("F\(f)") { selectedRouteFloor = f }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedRouteFloor == f ? Color.blue.opacity(0.15) : Color.clear)
                                .cornerRadius(8)
                        }
                    }
                }
            }

            ForEach(filteredRoutes, id: \.id) { rt in
                HStack {
                    Text(rt.id).bold()
                    Spacer()
                    if isManager { Image(systemName: "square.and.pencil") }
                }
                .contentShape(Rectangle())
                .onTapGesture { if isManager { sheet = .editRoute(rt) } }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isManager {
                        Button(role: .destructive) {
                            pendingDeleteRoute = rt
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("\(building.id) · Routes")
        .sheet(item: $sheet) { s in
            switch s {
            case .addRoom:
                RoomFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editRoom(let r):
                RoomFormView(buildingId: building.id, docId: r.id, initial: r) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .addRoute:
                RouteFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editRoute(let rt):
                RouteFormView(buildingId: building.id, docId: rt.id, initial: rt) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .addNode:
                NodeFormView(buildingId: building.id, docId: nil, initial: nil) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])

            case .editNode(let n):
                NodeFormView(buildingId: building.id, docId: n.id, initial: n) { _ in sheet = nil }
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Delete Route", isPresented: Binding(
            get: { pendingDeleteRoute != nil },
            set: { if !$0 { pendingDeleteRoute = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let rt = pendingDeleteRoute {
                    FS.deleteRoute(buildingId: building.id, docId: rt.id)
                }
                pendingDeleteRoute = nil
            }
        } message: {
            Text("This will delete \(pendingDeleteRoute?.id ?? "")")
        }
        .onAppear {
            routeListener?.remove()
            routeListener = FS.listenRoutes(buildingId: building.id) { docs in
                self.routes = docs.sorted { $0.id < $1.id }
            }
        }
        .onDisappear {
            routeListener?.remove()
        }
        .toolbar {
            if isManager {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sheet = .addRoute
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
    }
}

// Room 表单（不再写任何 node 信息，房间只存自己的字段）
struct RoomFormView: View {
    let buildingId: String
    let docId: String?
    let initial: RoomDoc?

    @State private var idText: String = ""
    @State private var profName = ""
    @State private var dept = ""
    @State private var office = ""
    @State private var floorStr = "0"
    @State private var roomType = ""

    @State private var errText: String? = nil
    var onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Document ID Example：F6-Room601")) {
                    TextField("Document ID", text: $idText).disabled(docId != nil)
                }
                Section {
                    TextField("Prof_name", text: $profName)
                    TextField("Department", text: $dept)
                    TextField("Office_hour", text: $office)
                    TextField("floor (Int)", text: $floorStr).keyboardType(.numberPad)
                    TextField("Room_type (required, e.g. office/lab/classroom)", text: $roomType)
                }

                if let errText { Section { Text(errText).foregroundStyle(.red) } }
            }
            .navigationTitle(docId == nil ? "Add Room" : "Modify Room")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmedId = idText.trimmingCharacters(in: .whitespaces)
                        let trimmedType = roomType.trimmingCharacters(in: .whitespaces)

                        guard !trimmedId.isEmpty else { errText = "Document ID cannot be empty"; return }
                        guard let floor = Int(floorStr) else { errText = "floor must be an integer"; return }
                        guard !trimmedType.isEmpty else { errText = "Room_type cannot be empty"; return }

                        let room = RoomDoc(id: trimmedId, data: [
                            "Prof_name": profName,
                            "Department": dept,
                            "Office_hour": office,
                            "floor": floor,
                            "Room_type": trimmedType
                        ])

                        FS.saveRoom(buildingId: buildingId, docId: trimmedId, room: room) { err in
                            if let err = err { errText = err.localizedDescription } else { onDone(true) }
                        }
                    }.bold()
                }
            }
            .onAppear {
                if let initial {
                    idText = initial.id
                    profName = initial.profName
                    dept = initial.department
                    office = initial.officeHour
                    floorStr = "\(initial.floor)"
                    roomType = initial.roomType
                }
            }
        }
    }
}

// Route 表单
struct RouteFormView: View {
    let buildingId: String
    let docId: String?
    let initial: RouteDoc?

    @State private var idText: String = ""
    @State private var keyEvents = ""
    @State private var steps = ""
    @State private var errText: String? = nil
    var onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Example: F6-Stair-to-F6-Room601")) {
                    TextField("Document ID", text: $idText).disabled(docId != nil)
                }
                Section("Key_events (JSON string)") {
                    TextEditor(text: $keyEvents).frame(minHeight: 120)
                }
                Section("Steps (JSON string)") {
                    TextEditor(text: $steps).frame(minHeight: 160)
                }
                if let errText { Section { Text(errText).foregroundStyle(.red) } }
            }
            .navigationTitle(docId == nil ? "Add Route" : "Edit Route")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmedId = idText.trimmingCharacters(in: .whitespaces)
                        guard !trimmedId.isEmpty else { errText = "Document ID cannot be empty"; return }
                        let route = RouteDoc(id: trimmedId, data: [
                            "Key_events": keyEvents,
                            "Steps": steps
                        ])
                        FS.saveRoute(buildingId: buildingId, docId: trimmedId, route: route) { err in
                            if let err = err { errText = err.localizedDescription } else { onDone(true) }
                        }
                    }.bold()
                }
            }
            .onAppear {
                if let initial {
                    idText = initial.id
                    keyEvents = initial.keyEventsJSONString
                    steps = initial.stepsJSONString
                }
            }
        }
    }
}

// 新建 Building 表单
struct NewBuildingFormView: View {
    @State private var idText: String = ""
    @State private var codeText: String = ""
    @State private var nameText: String = ""
    @State private var errText: String? = nil

    var onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("The document ID will be used as the document name under building, for example: Computing, Library, etc.")) {
                    TextField("Building ID（Necessary）", text: $idText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("Code（Necessary，Example：EEE、CPT）", text: $codeText)
                        .textInputAutocapitalization(.characters)
                    TextField("Name（Necessary，Example：Electrical Engineering And Electronics）", text: $nameText)
                }
                if let errText {
                    Section { Text(errText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add buildings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let id = idText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let code = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)

                        guard !id.isEmpty else { errText = "Building ID cannot be empty"; return }
                        guard !code.isEmpty else { errText = "Code cannot be empty"; return }
                        guard !name.isEmpty else { errText = "Name cannot be empty"; return }

                        FS.saveBuilding(id: id, code: code, name: name) { err in
                            if let err = err { errText = err.localizedDescription } else { onDone(true) }
                        }
                    }
                    .bold()
                }
            }
        }
    }
}

// 快速添加 Room（从首页）
struct QuickAddRoomView: View {
    @State private var buildings: [Building] = []
    @State private var selectedBuildingId: String? = nil

    @State private var roomIdText: String = ""
    @State private var profName = ""
    @State private var dept = ""
    @State private var office = ""
    @State private var floorStr = "0"
    @State private var roomType = ""

    @State private var nodes: [NodeDoc] = []
    @State private var nodeListener: ListenerRegistration?
    @State private var leftNodeId: String = ""
    @State private var rightNodeId: String = ""

    @State private var errText: String? = nil

    var onDone: (Bool) -> Void

    private var selectedFloorInt: Int? { Int(floorStr.trimmingCharacters(in: .whitespaces)) }

    private var nodesOnSelectedFloor: [NodeDoc] {
        guard let f = selectedFloorInt else { return [] }
        return nodes.filter { $0.floor == f }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Building") {
                    if buildings.isEmpty {
                        Text("Loading buildings…")
                    } else {
                        Picker("Building", selection: Binding(
                            get: { selectedBuildingId ?? buildings.first?.id ?? "" },
                            set: { newId in
                                selectedBuildingId = newId
                                startNodesListener(for: newId)
                                leftNodeId = ""
                                rightNodeId = ""
                            }
                        )) {
                            ForEach(buildings, id: \.id) { b in
                                Text(b.id).tag(b.id)
                            }
                        }
                    }
                }

                Section(footer: Text("Room document ID example: F6-Room601")) {
                    TextField("Room document ID (required)", text: $roomIdText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Prof_name", text: $profName)
                    TextField("Department", text: $dept)
                    TextField("Office_hour", text: $office)
                    TextField("floor (Int)", text: $floorStr)
                        .keyboardType(.numberPad)
                    TextField("Room_type (required, e.g. office/lab/classroom)", text: $roomType)
                }

                Section("Left and right nodes (optional, filtered by floor)") {
                    if nodesOnSelectedFloor.isEmpty {
                        Text("There are no available nodes on the current floor. Please add them in Nodes first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Node on the left of the room", selection: $leftNodeId) {
                            Text("None").tag("")
                            ForEach(nodesOnSelectedFloor, id: \.id) { n in
                                Text(n.id).tag(n.id)
                            }
                        }
                        Picker("Node on the right of the room", selection: $rightNodeId) {
                            Text("None").tag("")
                            ForEach(nodesOnSelectedFloor, id: \.id) { n in
                                Text(n.id).tag(n.id)
                            }
                        }

                        Text("Note: when facing the room door, the node on the left will write the room into that node’s right.rooms, and the node on the right will write it into its left.rooms.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errText {
                    Section { Text(errText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Room")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { saveRoomAndLinkNodes() }.bold() }
            }
            .onAppear { loadBuildingsIfNeeded() }
            .onDisappear { nodeListener?.remove() }
        }
    }

    private func loadBuildingsIfNeeded() {
        if !buildings.isEmpty { return }

        Firestore.firestore().collection("building").getDocuments { snapshot, error in
            if let error = error {
                errText = "Failed to load buildings: \(error.localizedDescription)"
                return
            }
            let docs = snapshot?.documents ?? []
            buildings = docs.map { Building(id: $0.documentID, data: $0.data()) }
            if selectedBuildingId == nil, let first = buildings.first {
                selectedBuildingId = first.id
                startNodesListener(for: first.id)
            }
        }
    }

    private func startNodesListener(for buildingId: String) {
        nodeListener?.remove()
        nodeListener = FS.listenNodes(buildingId: buildingId) { docs in
            self.nodes = docs.sorted { $0.id < $1.id }
        }
    }

    private func saveRoomAndLinkNodes() {
        errText = nil

        let trimmedRoomId = roomIdText.trimmingCharacters(in: .whitespaces)
        let trimmedType = roomType.trimmingCharacters(in: .whitespaces)

        guard !trimmedRoomId.isEmpty else { errText = "Room document ID cannot be empty"; return }
        guard let buildingId = (selectedBuildingId ?? buildings.first?.id),
              !buildingId.isEmpty else { errText = "Please select a building"; return }
        guard let floor = Int(floorStr) else { errText = "floor must be an integer"; return }
        guard !trimmedType.isEmpty else { errText = "Room_type cannot be empty"; return }

        let room = RoomDoc(id: trimmedRoomId, data: [
            "Prof_name": profName,
            "Department": dept,
            "Office_hour": office,
            "floor": floor,
            "Room_type": trimmedType
        ])

        FS.saveRoom(buildingId: buildingId, docId: trimmedRoomId, room: room) { err in
            if let err = err { errText = err.localizedDescription; return }

            FS.linkRoomToNodes(
                buildingId: buildingId,
                roomId: trimmedRoomId,
                leftNodeId: leftNodeId,
                rightNodeId: rightNodeId
            ) { linkErr in
                if let linkErr = linkErr {
                    errText = "Room was created, but updating nodes failed: \(linkErr.localizedDescription)"
                } else {
                    onDone(true)
                }
            }
        }
    }
}

// 在某个楼栋下编辑 / 新建 Node
struct NodeFormView: View {
    let buildingId: String
    let docId: String?
    let initial: NodeDoc?

    @State private var idText: String = ""
    @State private var floorStr: String = "0"
    @State private var nearestStair: String = ""
    @State private var nearestElev: String = ""
    @State private var leftNextNode: String = ""
    @State private var leftRoomsText: String = ""
    @State private var rightNextNode: String = ""
    @State private var rightRoomsText: String = ""

    @State private var errText: String? = nil
    var onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Node document ID example: F6-Node-A")) {
                    TextField("Node document ID (required)", text: $idText)
                        .disabled(docId != nil)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("floor (Int)", text: $floorStr)
                        .keyboardType(.numberPad)
                    TextField("nearest_stair (optional)", text: $nearestStair)
                    TextField("nearest_elev (optional)", text: $nearestElev)
                }

                Section("left direction") {
                    TextField("left.next_node", text: $leftNextNode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("left.rooms (comma separated)", text: $leftRoomsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("right direction") {
                    TextField("right.next_node", text: $rightNextNode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("right.rooms (comma separated)", text: $rightRoomsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let errText {
                    Section { Text(errText).foregroundColor(.red) }
                }
            }
            .navigationTitle(docId == nil ? "Add Node" : "Edit Node")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmedId = idText.trimmingCharacters(in: .whitespaces)
                        guard !trimmedId.isEmpty else { errText = "Node document ID cannot be empty"; return }
                        guard let floor = Int(floorStr) else { errText = "floor must be an integer"; return }

                        let leftRooms = leftRoomsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        let rightRooms = rightRoomsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        let node = NodeDoc(
                            id: trimmedId,
                            floor: floor,
                            nearestStair: nearestStair.trimmingCharacters(in: .whitespaces),
                            nearestElev: nearestElev.trimmingCharacters(in: .whitespaces),
                            leftNextNode: leftNextNode.trimmingCharacters(in: .whitespaces),
                            leftRooms: leftRooms,
                            rightNextNode: rightNextNode.trimmingCharacters(in: .whitespaces),
                            rightRooms: rightRooms
                        )

                        FS.saveNode(buildingId: buildingId, docId: trimmedId, node: node) { err in
                            if let err = err { errText = err.localizedDescription } else { onDone(true) }
                        }
                    }
                }
            }
            .onAppear {
                if let initial {
                    idText = initial.id
                    floorStr = "\(initial.floor)"
                    nearestStair = initial.nearestStair
                    nearestElev = initial.nearestElev
                    leftNextNode = initial.leftNextNode
                    leftRoomsText = initial.leftRooms.joined(separator: ",")
                    rightNextNode = initial.rightNextNode
                    rightRoomsText = initial.rightRooms.joined(separator: ",")
                }
            }
        }
    }
}

// 快速添加 Node（从首页）
struct QuickAddNodeView: View {
    @State private var buildings: [Building] = []
    @State private var selectedBuildingId: String? = nil

    @State private var nodeIdText: String = ""
    @State private var floorStr: String = "0"
    @State private var nearestStair: String = ""
    @State private var nearestElev: String = ""
    @State private var leftNextNode: String = ""
    @State private var leftRoomsText: String = ""
    @State private var rightNextNode: String = ""
    @State private var rightRoomsText: String = ""

    @State private var errText: String? = nil

    var onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Building") {
                    if buildings.isEmpty {
                        Text("Loading buildings…")
                    } else {
                        Picker("Building", selection: Binding(
                            get: { selectedBuildingId ?? buildings.first?.id ?? "" },
                            set: { selectedBuildingId = $0 }
                        )) {
                            ForEach(buildings, id: \.id) { b in
                                Text(b.id).tag(b.id)
                            }
                        }
                    }
                }

                Section(footer: Text("Node document ID example: F6-Node-A")) {
                    TextField("Node document ID (required)", text: $nodeIdText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("floor (Int)", text: $floorStr)
                        .keyboardType(.numberPad)
                    TextField("nearest_stair (optional, e.g. S1)", text: $nearestStair)
                    TextField("nearest_elev (optional, e.g. E1)", text: $nearestElev)
                }

                Section("left direction (optional)") {
                    TextField("left.next_node (e.g. F6-Node-B)", text: $leftNextNode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("left.rooms (comma separated, e.g. F6-Room601,F6-Room602)", text: $leftRoomsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("right direction (optional)") {
                    TextField("right.next_node (e.g. F6-Node-C)", text: $rightNextNode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("right.rooms (comma separated, e.g. F6-Room603)", text: $rightRoomsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let errText {
                    Section { Text(errText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Node")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmedNodeId = nodeIdText.trimmingCharacters(in: .whitespaces)
                        guard !trimmedNodeId.isEmpty else { errText = "Node document ID cannot be empty"; return }

                        guard let buildingId = (selectedBuildingId ?? buildings.first?.id),
                              !buildingId.isEmpty else { errText = "Please select a building"; return }

                        guard let floor = Int(floorStr) else { errText = "floor must be an integer"; return }

                        let leftRooms = leftRoomsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        let rightRooms = rightRoomsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        let node = NodeDoc(
                            id: trimmedNodeId,
                            floor: floor,
                            nearestStair: nearestStair.trimmingCharacters(in: .whitespaces),
                            nearestElev: nearestElev.trimmingCharacters(in: .whitespaces),
                            leftNextNode: leftNextNode.trimmingCharacters(in: .whitespaces),
                            leftRooms: leftRooms,
                            rightNextNode: rightNextNode.trimmingCharacters(in: .whitespaces),
                            rightRooms: rightRooms
                        )

                        FS.saveNode(buildingId: buildingId, docId: trimmedNodeId, node: node) { err in
                            if let err = err { errText = err.localizedDescription } else { onDone(true) }
                        }
                    }
                    .bold()
                }
            }
            .onAppear {
                Firestore.firestore().collection("building").getDocuments { snapshot, error in
                    if let error = error {
                        errText = "Failed to load buildings: \(error.localizedDescription)"
                        return
                    }
                    let docs = snapshot?.documents ?? []
                    buildings = docs.map { Building(id: $0.documentID, data: $0.data()) }
                    if selectedBuildingId == nil {
                        selectedBuildingId = buildings.first?.id
                    }
                }
            }
        }
    }
}
