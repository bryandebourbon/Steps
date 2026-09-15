import Foundation

enum LoadState: Equatable {
    case loading
    case ready
    case empty
    case failed(String)
}
