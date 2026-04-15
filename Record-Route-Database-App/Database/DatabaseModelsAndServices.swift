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
// MARK: - 二、Database 部分
// =======================================================

struct Building: Identifiable, Hashable {
    let id: String
    var code: String?
    var name: String?
    init(id: String, data: [String: Any]) {
        self.id = id
        self.code = data["Code"] as? String
        self.name = data["Name"] as? String
    }
}

struct RoomDoc: Identifiable, Hashable {
    let id: String
    var profName: String
    var department: String
    var officeHour: String
    var floor: Int
    var roomType: String      // Room_type（必填）

    init(id: String, data: [String: Any]) {
        self.id = id
        self.profName = data["Prof_name"] as? String ?? ""
        self.department = data["Department"] as? String ?? ""
        self.officeHour = data["Office_hour"] as? String ?? ""
        self.floor = data["floor"] as? Int ?? 0
        self.roomType = data["Room_type"] as? String ?? ""   // 兼容旧数据，默认空字符串
    }

    var asMap: [String: Any] {
        [
            "Prof_name": profName,
            "Department": department,
            "Office_hour": officeHour,
            "floor": floor,
            "Room_type": roomType
        ]
    }
}

struct RouteDoc: Identifiable, Hashable {
    let id: String
    var keyEventsJSONString: String
    var stepsJSONString: String
    var totalSteps: Int

    init(id: String, data: [String: Any]) {
        self.id = id
        self.keyEventsJSONString = data["Key_events"] as? String ?? ""
        self.stepsJSONString = data["Steps"] as? String ?? ""
        self.totalSteps = data["Total_steps"] as? Int ?? 0
    }

    var asMap: [String: Any] {
        [
            "Key_events": keyEventsJSONString,
            "Steps": stepsJSONString,
            "Total_steps": totalSteps
        ]
    }
}

// Node 文档（building/{bid}/nodes/{nodeId}）
struct NodeDoc: Identifiable, Hashable {
    let id: String
    var floor: Int
    var nearestStair: String
    var nearestElev: String
    var leftNextNode: String
    var leftRooms: [String]
    var rightNextNode: String
    var rightRooms: [String]

    init(id: String, data: [String: Any]) {
        self.id = id
        self.floor = data["floor"] as? Int ?? 0
        self.nearestStair = data["nearest_stair"] as? String ?? ""
        self.nearestElev = data["nearest_elev"] as? String ?? ""
        if let left = data["left"] as? [String: Any] {
            self.leftNextNode = left["next_node"] as? String ?? ""
            self.leftRooms = left["rooms"] as? [String] ?? []
        } else {
            self.leftNextNode = ""
            self.leftRooms = []
        }
        if let right = data["right"] as? [String: Any] {
            self.rightNextNode = right["next_node"] as? String ?? ""
            self.rightRooms = right["rooms"] as? [String] ?? []
        } else {
            self.rightNextNode = ""
            self.rightRooms = []
        }
    }

    init(id: String,
         floor: Int,
         nearestStair: String,
         nearestElev: String,
         leftNextNode: String,
         leftRooms: [String],
         rightNextNode: String,
         rightRooms: [String]) {
        self.id = id
        self.floor = floor
        self.nearestStair = nearestStair
        self.nearestElev = nearestElev
        self.leftNextNode = leftNextNode
        self.leftRooms = leftRooms
        self.rightNextNode = rightNextNode
        self.rightRooms = rightRooms
    }

    var asMap: [String: Any] {
        var map: [String: Any] = [
            "floor": floor
        ]
        if !nearestStair.isEmpty { map["nearest_stair"] = nearestStair }
        if !nearestElev.isEmpty { map["nearest_elev"] = nearestElev }
        map["left"] = [
            "next_node": leftNextNode,
            "rooms": leftRooms
        ]
        map["right"] = [
            "next_node": rightNextNode,
            "rooms": rightRooms
        ]
        return map
    }
}

// 管理员判断
final class ManagerGate: ObservableObject {
    @Published var isManager = false
    @Published var allowedBuildings: [String]? = nil
    @Published var checked = false
    private var listener: ListenerRegistration?

    func start() {
        checked = false

        guard let uid = Auth.auth().currentUser?.uid else {
            isManager = false
            allowedBuildings = nil
            listener?.remove()
            listener = nil
            checked = true
            return
        }
        let docRef = Firestore.firestore().collection("managers").document(uid)
        listener?.remove()
        listener = docRef.addSnapshotListener { [weak self] snap, _ in
            guard let self else { return }
            if let s = snap, s.exists {
                self.isManager = true
                self.allowedBuildings = s.data()?["building"] as? [String]
            } else {
                self.isManager = false
                self.allowedBuildings = nil
            }
            self.checked = true
        }
    }
    deinit { listener?.remove() }
}

// Auth VM
final class AuthVM: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var errorText: String? = nil
    @Published var user: User? = Auth.auth().currentUser
    private var handle: AuthStateDidChangeListenerHandle?
    init() {
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.user = user
        }
    }
    func signIn() {
        errorText = nil
        Auth.auth().signIn(withEmail: email, password: password) { [weak self] _, err in
            if let err = err { self?.errorText = err.localizedDescription }
        }
    }
    func signOut() {
        do { try Auth.auth().signOut() } catch { errorText = error.localizedDescription }
    }
    deinit { if let handle { Auth.auth().removeStateDidChangeListener(handle) } }
}

// Firestore 封装（Rooms / Routes / Nodes 都首字母大写）
final class FS {
    static let db = Firestore.firestore()

    // MARK: - Buildings
    static func listenBuildings(_ onChange: @escaping ([Building]) -> Void) -> ListenerRegistration {
        db.collection("building")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let list = docs.map { Building(id: $0.documentID, data: $0.data()) }
                onChange(list)
            }
    }

    static func saveBuilding(
        id: String,
        code: String?,
        name: String?,
        completion: ((Error?) -> Void)? = nil
    ) {
        var map: [String: Any] = [:]
        if let code { map["Code"] = code }
        if let name { map["Name"] = name }

        db.collection("building")
            .document(id)
            .setData(map, merge: true, completion: completion)
    }

    // MARK: - Rooms
    static func listenRooms(
        buildingId: String,
        _ onChange: @escaping ([RoomDoc]) -> Void
    ) -> ListenerRegistration {
        db.collection("building")
            .document(buildingId)
            .collection("Rooms")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let list = docs.map { RoomDoc(id: $0.documentID, data: $0.data()) }
                onChange(list)
            }
    }

    static func saveRoom(
        buildingId: String,
        docId: String,
        room: RoomDoc,
        completion: ((Error?) -> Void)? = nil
    ) {
        db.collection("building")
            .document(buildingId)
            .collection("Rooms")
            .document(docId)
            .setData(room.asMap, merge: true, completion: completion)
    }

    static func deleteRoom(
        buildingId: String,
        docId: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        db.collection("building")
            .document(buildingId)
            .collection("Rooms")
            .document(docId)
            .delete(completion: completion)
    }

    // MARK: - Routes
    static func listenRoutes(
        buildingId: String,
        _ onChange: @escaping ([RouteDoc]) -> Void
    ) -> ListenerRegistration {
        db.collection("building")
            .document(buildingId)
            .collection("Routes")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let list = docs.map { RouteDoc(id: $0.documentID, data: $0.data()) }
                onChange(list)
            }
    }

    static func saveRoute(
        buildingId: String,
        docId: String,
        route: RouteDoc,
        completion: ((Error?) -> Void)? = nil
    ) {
        db.collection("building")
            .document(buildingId)
            .collection("Routes")
            .document(docId)
            .setData(route.asMap, merge: true, completion: completion)
    }

    static func deleteRoute(
        buildingId: String,
        docId: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        db.collection("building")
            .document(buildingId)
            .collection("Routes")
            .document(docId)
            .delete(completion: completion)
    }

    // MARK: - Nodes

    static func saveNode(buildingId: String, docId: String, node: NodeDoc, completion: ((Error?) -> Void)? = nil) {
        db.collection("building")
            .document(buildingId)
            .collection("Nodes")
            .document(docId)
            .setData(node.asMap, merge: true, completion: completion)
    }

    static func deleteNode(buildingId: String, docId: String, completion: ((Error?) -> Void)? = nil) {
        db.collection("building")
            .document(buildingId)
            .collection("Nodes")
            .document(docId)
            .delete(completion: completion)
    }

    static func listenNodes(buildingId: String, _ onChange: @escaping ([NodeDoc]) -> Void) -> ListenerRegistration {
        db.collection("building")
            .document(buildingId)
            .collection("Nodes")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                onChange(docs.map { NodeDoc(id: $0.documentID, data: $0.data()) })
            }
    }

    static func linkRoomToNodes(
        buildingId: String,
        roomId: String,
        leftNodeId: String?,
        rightNodeId: String?,
        completion: ((Error?) -> Void)? = nil
    ) {
        let group = DispatchGroup()
        var firstError: Error?

        func update(nodeId: String, fieldPath: String) {
            guard !nodeId.isEmpty else { return }
            group.enter()
            let ref = db.collection("building")
                .document(buildingId)
                .collection("Nodes")
                .document(nodeId)
            ref.setData([fieldPath: FieldValue.arrayUnion([roomId])],
                        merge: true) { err in
                if let err, firstError == nil {
                    firstError = err
                }
                group.leave()
            }
        }

        if let left = leftNodeId, !left.isEmpty {
            update(nodeId: left, fieldPath: "right.rooms")
        }

        if let right = rightNodeId, !right.isEmpty {
            update(nodeId: right, fieldPath: "left.rooms")
        }

        group.notify(queue: .main) {
            completion?(firstError)
        }
    }
}

// =======================================================
