import Foundation
import AppKit

/// Quietly builds the Discover caches for the whole library — no "Scan" button,
/// no folder prompt, no progress window. Runs on an idle utility queue shortly
/// after launch, incrementally, and picks up newly added photos automatically.
/// People / Places / Duplicates read the finished tables instantly.
final class DiscoverIndexer {
    static let shared = DiscoverIndexer()

    private let queue = DispatchQueue(label: "com.galleria.discover", qos: .utility)
    private var started = false
    private var step = 0
    private var total = 0

    /// Called once from LibraryStore after the initial catalogue refresh.
    func start(store: LibraryStore) {
        queue.async {
            guard !self.started else { return }
            self.started = true
            // Give the launch rescan and the first grid paint room to breathe.
            self.queue.asyncAfter(deadline: .now() + 3) {
                self.tick(store: store)
            }
        }
    }

    private func tick(store: LibraryStore) {
        queue.async {
            // During a library scan the file list is in flux; wait it out.
            if store.isScanning {
                self.reschedule(store: store, delay: 4)
                return
            }

            if let work = store.nextDiscoverWork() {
                switch work.kind {
                case .geo:
                    if let coord = GeoHelper.coordinate(path: work.path) {
                        store.setGeo(photoID: work.photoID,
                                     latitude: coord.latitude, longitude: coord.longitude)
                    } else {
                        store.setGeo(photoID: work.photoID,
                                     latitude: LibraryStore.noGeoLatitude, longitude: 0)
                    }
                case .hash:
                    store.setHash(photoID: work.photoID,
                                  hash: DuplicateFinder.perceptualHash(path: work.path) ?? 0)
                case .faces:
                    store.setFaceCount(photoID: work.photoID,
                                       faces: FaceDetector.faceCount(path: work.path))
                }

                self.step += 1
                if self.step % 20 == 0 { self.publishProgress(store: store) }
                self.reschedule(store: store, delay: 0.05)
            } else {
                // Everything is indexed — go quiet until new photos appear.
                self.publishProgress(store: store)
                DispatchQueue.main.async {
                    store.discoverIndexed = store.totalCount
                    store.discoverTotal = store.totalCount
                    store.discoverDone = true
                }
                self.reschedule(store: store, delay: 25)
            }
        }
    }

    private func reschedule(store: LibraryStore, delay: Double) {
        queue.asyncAfter(deadline: .now() + delay) {
            self.tick(store: store)
        }
    }

    private func publishProgress(store: LibraryStore) {
        let remaining = store.discoverRemaining()
        let total = store.totalCount
        DispatchQueue.main.async {
            store.discoverTotal = total
            store.discoverIndexed = max(0, total - remaining)
            store.discoverDone = remaining == 0
        }
    }
}
