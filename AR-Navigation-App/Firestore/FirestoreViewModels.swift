import ActivityKit
import SwiftUI
import ARKit
import SceneKit
import simd
import Combine
import AVFoundation
import UniformTypeIdentifiers
import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
// MARK: - Firestore ViewModels

final class RoutePickerViewModel: ObservableObject {
    @Published var routes: [FirestoreRoute] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func loadRoutes(for startInfo: StartInfo) {
        isLoading = true
        errorMessage = nil
        routes = []

        guard let buildingId = startInfo.building, !buildingId.isEmpty else {
            self.isLoading = false
            self.errorMessage = "QR code does not contain building info, cannot load routes"
            return
        }

        db.collection("building")
            .document(buildingId)
            .collection("Routes")
            .getDocuments { [weak self] snap, error in
                DispatchQueue.main.async {
                    self?.isLoading = false
                    if let error = error {
                        self?.errorMessage = "Failed to load routes: \(error.localizedDescription)"
                        return
                    }
                    guard let snap = snap else { return }
                    self?.routes = snap.documents.compactMap { FirestoreRoute(doc: $0) }
                }
            }
    }
}

final class RoomsViewModel: ObservableObject {
    @Published var rooms: [RoomInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func loadRooms(for startInfo: StartInfo) {
        isLoading = true
        errorMessage = nil
        rooms = []

        guard let buildingId = startInfo.building, !buildingId.isEmpty else {
            self.isLoading = false
            self.errorMessage = "QR code does not contain building info, cannot load room list"
            return
        }

        db.collection("building")
            .document(buildingId)
            .collection("Rooms")
            .getDocuments { [weak self] snap, error in
                DispatchQueue.main.async {
                    self?.isLoading = false
                    if let error = error {
                        self?.errorMessage = "Failed to load rooms: \(error.localizedDescription)"
                        return
                    }
                    guard let snap = snap else { return }

                    let list: [RoomInfo] = snap.documents.compactMap { doc in
                        let data = doc.data()
                        let nameField = data["name"] as? String
                        let roomName = (nameField?.isEmpty == false) ? nameField! : doc.documentID

                        let prof = data["Prof_name"] as? String
                        let dept = data["Department"] as? String
                        let office = data["Office_hour"] as? String

                        var floorValue: Int? = nil
                        if let f = data["floor"] as? Int { floorValue = f }
                        else if let s = data["floor"] as? String, let f = Int(s) { floorValue = f }

                        return RoomInfo(
                            id: doc.documentID,
                            name: roomName,
                            professor: prof,
                            department: dept,
                            officeHour: office,
                            floor: floorValue
                        )
                    }

                    self?.rooms = list
                    if list.isEmpty { self?.errorMessage = "No room information found for this building (Rooms subcollection is empty)" }
                }
            }
    }
}
