//
//  Deluge Client.swift
//  Deluge Remote
//
//  Created by Rudy Bermudez on 7/16/16.
//  Copyright © 2016 Rudy Bermudez. All rights reserved.
//

import Alamofire
import Foundation
import Houston
import PromiseKit

typealias JSON = [String: Any]

enum ClientError: Error {
    case incorrectPassword
    case unexpectedResponse
    case torrentCouldNotBeParsed
    case unexpectedError(String)
    case unableToPauseTorrent(Error)
    case unableToResumeTorrent(Error)
    case unableToParseTableViewTorrent
    case unableToDeleteTorrent
    case unableToAddTorrent
    case uploadFailed
    case unableToParseTorrentInfo
    case failedToConvertTorrentToData
    case noHostsExist
    case hostNotOnline

    // swiftlint:disable:next cyclomatic_complexity
    func domain() -> String {
        switch self {
        case .uploadFailed:
            return "Unable to Upload Torrent"
        case .incorrectPassword:
            return "Incorrect Password, Unable to Authenticate"
        case .torrentCouldNotBeParsed:
            return "Error Parsing Torrent Data Points"
        case .unexpectedResponse:
            return "Unexpected Response from Server"
        case .unexpectedError(let errorMessage):
            return errorMessage
        case .unableToPauseTorrent(let errorMessage):
            return "Unable to Pause Torrent. \(errorMessage.localizedDescription)"
        case .unableToResumeTorrent(let errorMessage):
            return "Unable to Resume Torrent. \(errorMessage.localizedDescription)"
        case .unableToParseTableViewTorrent:
            return "The Data for Table View Torrent was unable to be parsed"
        case .unableToDeleteTorrent:
            return "The Torrent could not be deleted"
        case .unableToAddTorrent:
            return "The Torrent could not be added"
        case .unableToParseTorrentInfo:
            return "The Torrent Info could not be parsed"
        case .failedToConvertTorrentToData:
            return "Conversion from URL to Data failed"
        case .hostNotOnline:
            return "Unable to Connect to Host because Daemon is offline."
        case .noHostsExist:
            return "No Deluge Daemons are configured in the webUI."
        }
    }
}

enum NetworkSecurity {
    case https(port: String)
    case http(port: String)

    func port() -> String {
        switch self {
        case .https(let port):
            return port
        case .http(let port):
            return port
        }
    }

    func name() -> String {
        switch self {
        case .https:
            return "https://"
        default:
            return "http://"
        }
    }
}

enum APIResult <T> {
    case success(T)
    case failure(Error)
}

/**
 API to manage remote Deluge server. Allows user to view, add, pause, resume, and remove torrents
 
 - Important: Must Call `DelugeClient.authenticate()` before any other method
 or else methods will propagate errors and Promises will be rejected
 */
class DelugeClient {
    //  swiftlint:disable:previous type_body_length
    let clientConfig: ClientConfig

    private var Manager: Alamofire.SessionManager

    /// Dispatch Queue used for JSON Serialization
    let utilityQueue: DispatchQueue

    init(config: ClientConfig) {
        self.clientConfig = config
        self.utilityQueue = DispatchQueue.global(qos: .userInitiated)

        // Create the server trust policies
        let serverTrustPolicies: [String: ServerTrustPolicy] = [
            self.clientConfig.hostname: .disableEvaluation
        ]
        // Create custom manager
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5 // 5 second timeout
        configuration.httpAdditionalHeaders = Alamofire.SessionManager.defaultHTTPHeaders
        Manager = Alamofire.SessionManager(
            configuration: configuration,
            serverTrustPolicyManager: ServerTrustPolicyManager(policies: serverTrustPolicies)
        )
        Manager.retrier = DelugeClientRequestRetrier()
    }

    func authenticateAndConnect() -> Promise<Void> {

        return authenticate()
            .then { [weak self] isValid -> Promise<[Host]> in
                guard let self = self, isValid else {
                    throw ClientError.incorrectPassword
                }
                return self.getHosts()
            }.then { [weak self] host -> Promise<HostStatus> in
                guard let self = self, let host = host.first else {
                    throw ClientError.noHostsExist
                }
                return self.getHostStatus(for: host)
            }.then { [weak self] host -> Promise<Void> in
                guard let self = self else {
                    throw ClientError.unexpectedError("Self does not exist")
                }
                if host.status == "Online" {
                    return self.connect(to: host)
                } else if host.status == "Connected" {
                    return Promise<Void>()
                } else {
                    throw ClientError.hostNotOnline
                }
        }
    }

    /**
     Authenticates the user to Deluge Server.
     
     - Important: This function must be called before any other function.
     
     - Note: Uses `DelugeClient.validateCredentials`
     
     - Returns: `Promise<Bool>`. returns `true` if connection was successful
     
     - A rejected Promise if the authenication fails
     - Possible Errors Propagated to Promise:
     - ClientError.unexpectedResponse if the json cannot be parsed
     - ClientError.incorrectPassword if the server responds the responce was false
     
     */
    private func authenticate() -> Promise<Bool> {
        let parameters: Parameters = [
            "id": arc4random(),
            "method": "auth.login",
            "params": [clientConfig.password]
        ]

        return Promise { seal in
            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseJSON { response in
                    switch response.result {
                    case .success(let data):
                        let json = data as? JSON
                        guard let result = json?["result"] as? Bool else {
                            seal.reject(ClientError.unexpectedResponse)
                            break
                        }
                        seal.fulfill(result)

                    case .failure(let error):
                        seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }

    /**
     Retrieves all data points for a torrent
     
     - precondition: `DelugeClient.authenticate()` must have been called or
     else `Promise` will be rejected with an error
     
     - Parameter hash: A `String` representation of a hash for a specific torrent the user would like query
     
     - Returns: A `Promise` embedded with an instance of `Torrent`
     */
    func getTorrentDetails(withHash hash: String) -> Promise<TorrentMetadata> {
        return Promise { seal in
            let parameters: Parameters = [
                "id": arc4random(),
                "method": "core.get_torrent_status",
                "params": [hash, []]
            ]

            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseData(queue: utilityQueue) { response in

                    switch response.result {
                    case .success(let data):

                        do {
                            let torrent = try
                                JSONDecoder().decode(DelugeResponse<TorrentMetadata>.self, from: data )
                            seal.fulfill(torrent.result)
                        } catch let error {
                            Logger.error(error)
                            seal.reject(ClientError.torrentCouldNotBeParsed)
                        }

                    case .failure(let error): seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }
    /**
     Retreives data for all torrents and creates an array of `TableViewTorrent`
     
     - precondition: `DelugeClient.authenticate()` must have been called
     or else `Promise` will be rejected with an error
     
     - Returns: A `Promise` embedded with a TableViewTorrent
     */
    func getAllTorrents() -> Promise<[TorrentOverview]> {
        let parameters: Parameters = [
            "id": arc4random(),
            "method": "core.get_torrents_status",
            "params": [[], ["name", "hash", "upload_payload_rate", "download_payload_rate", "ratio",
                            "progress", "total_wanted", "state", "tracker_host", "label", "eta",
                            "total_size", "all_time_download", "total_uploaded", "time_added"]]
        ]

        return Promise { seal in

            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseData(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let data):

                        do {
                            let response = try JSONDecoder()
                                .decode(DelugeResponse<[String: TorrentOverview]>.self, from: data)
                            seal.fulfill(Array(response.result.values))
                        } catch {
                            seal.reject(ClientError.unableToParseTableViewTorrent)
                            Logger.error(error)
                        }

                    case .failure(let error):
                        seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }
    /**
     Pause an individual torrent
     
     - precondition: `DelugeClient.authenticate()` must have been called or else `APIResult` will fail with an error
     
     - Parameter hash: the hash as a `String` of the torrent the user would like to pause
     - Parameter onCompletion: An escaping block that returns a `APIResult<T>` when the request is completed.
     This block returns a `APIResult<Bool>`
     */
    func pauseTorrent(withHash hash: String, onCompletion: @escaping (APIResult<Void>) -> Void) {
        let parameters: Parameters =  [
            "id": arc4random(),
            "method": "core.pause_torrent",
            "params": [[hash]]
        ]

        Manager.request(clientConfig.url, method: .post, parameters: parameters,
                        encoding: JSONEncoding.default).validate().responseJSON(queue: utilityQueue) { response in
                            switch response.result {
                            case .success: onCompletion(.success(()))
                            case .failure(let error): onCompletion(.failure(ClientError.unableToPauseTorrent(error)))
                            }
        }
    }

    /**
     Pause all torrents in deluge client
     
     - precondition: `DelugeClient.authenticate()` must have been called or else `APIResult` will fail with an error
     
     - Parameter onCompletion: An escaping block that returns a `APIResult<T>` when the request is completed.
     If the request is successful, this block returns a APIResult.success(_) with no data.
     If it fails, it will return APIResult.error(Error)
     
     
     deluge.pauseAllTorrents { (result) in
     switch result {
     case .success(_): print("All Torrents Paused")
     case .failure(let error): print(error)
     }
     }
     */
    func pauseAllTorrents(onCompletion: @escaping (APIResult<Any>) -> Void) {
        let parameters: Parameters = [
            "id": arc4random(),
            "method": "core.pause_all_torrents",
            "params": []
        ]

        Manager.request(clientConfig.url, method: .post, parameters: parameters,
                        encoding: JSONEncoding.default).validate().responseJSON(queue: utilityQueue) { response in
                            switch response.result {
                            case .success: onCompletion(.success(Any.self))
                            case .failure(let error): onCompletion(.failure(ClientError.unableToPauseTorrent(error)))
                            }
        }
    }

    /**
     Resume an individual torrent
     
     - precondition: `DelugeClient.authenticate()` must have been called or else `APIResult` will fail with an error
     
     - Parameters:
     - hash: the hash as a `String` of the torrent the user would like to resume
     - onCompletion: An escaping block that returns a `APIResult<T>` when the request is completed.
     This block returns a `APIResult<Bool>`
     */
    func resumeTorrent(withHash hash: String, onCompletion: @escaping (APIResult<Void>) -> Void) {
        let parameters: Parameters =  [
            "id": arc4random(),
            "method": "core.resume_torrent",
            "params": [[hash]]
        ]

        Manager.request(clientConfig.url, method: .post, parameters: parameters,
                        encoding: JSONEncoding.default).validate().responseJSON(queue: utilityQueue) { response in
                            switch response.result {
                            case .success: onCompletion(APIResult.success(()))
                            case .failure(let error): onCompletion(APIResult.failure(
                                ClientError.unableToResumeTorrent(error)))
                            }
        }
    }

    /**
     Resume all torrents in deluge client
     
     - precondition: `DelugeClient.authenticate()` must have been called or else `APIResult` will fail with an error
     
     - Parameter onCompletion: An escaping block that returns a `APIResult<T>` when the request is completed.
     This block returns a `APIResult<Any>`
     */
    func resumeAllTorrents(onCompletion: @escaping (APIResult<Any>) -> Void) {
        let parameters: Parameters = [
            "id": arc4random(),
            "method": "core.resume_all_torrents",
            "params": []
        ]

        Manager.request(clientConfig.url, method: .post, parameters: parameters,
                        encoding: JSONEncoding.default).validate().responseJSON(queue: utilityQueue) { response in
                            switch response.result {
                            case .success: onCompletion(.success(Any.self))
                            case .failure(let error): onCompletion(.failure(ClientError.unableToResumeTorrent(error)))
                            }
        }
    }

    /**
     Removes a Torrent from the client with the option to remove the data
     
     - precondition: `DelugeClient.authenticate()` must have been called
     or else `Promise` will be rejected with an error
     
     - Parameters:
     - hash: The hash as a String of the torrent the user would like to delete
     - removeData: `true` if the user would like to remove torrent and torrent data.
     `false` if the user would like to delete the torrent but keep the torrent data
     
     - Returns:  `Promise<Bool>`. If successful, bool will always be true.
     */
    func removeTorrent(withHash hash: String, removeData: Bool) -> Promise <Void> {
        return Promise { seal in
            let parameters: Parameters = [
                "id": arc4random(),
                "method": "core.remove_torrent",
                "params": [hash, removeData]
            ]
            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let data):
                        guard let json = data as? JSON, let result = json["result"] as? Bool else {
                            seal.reject(ClientError.unexpectedResponse)
                            break
                        }
                        (result == true) ? seal.fulfill(()) : seal.reject(ClientError.unableToDeleteTorrent)
                    case .failure(let error):
                        seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }

    func addTorrentMagnet(url: URL, with config: TorrentConfig) -> Promise<Void> {

        // TODO: Add File Priorities

        let parameters: Parameters = [
            "id": arc4random(),
            "method": "core.add_torrent_magnet",
            "params": [url.absoluteString, config.toParams()]
        ]

        return Promise { seal in
            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let json):
                        // swiftlint:disable:next unused_optional_binding
                        guard let json = json as? [String: Any], let _ = json["result"] as? String else {
                            seal.reject(ClientError.unableToAddTorrent)
                            return
                        }
                        seal.fulfill(())
                    case .failure(let error): seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }

    func getMagnetInfo(url: URL) -> Promise<(name: String, hash: String)> {
        let parameters: Parameters = [
            "id": arc4random(),
            "method": "web.get_magnet_info",
            "params": [url.absoluteString]
        ]

        return Promise<(name: String, hash: String)> { seal in
            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let json):
                        guard
                            let json = json as? JSON,
                            let result = json["result"] as? JSON,
                            let name = result["name"] as? String,
                            let hash = result["info_hash"] as? String
                            else {
                                seal.reject(ClientError.unexpectedResponse)
                                return
                        }
                        seal.fulfill((name: name, hash: hash))
                    case .failure(let error): seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }

    func addTorrentFile(fileName: String, torrent: Data, with config: TorrentConfig) -> Promise<Void> {

        return Promise { seal in

            let parameters: Parameters = [
                "id": arc4random(),
                "method": "core.add_torrent_file",
                "params": [fileName, torrent.base64EncodedString(), config.toParams()]
            ]

            Manager.request(clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let json):
                        // swiftlint:disable:next unused_optional_binding
                        guard let json = json as? [String: Any], let _ = json["result"] as? String else {
                            seal.reject(ClientError.unableToAddTorrent)
                            return
                        }
                        seal.fulfill(())
                    case .failure(let error): seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }

    private func upload(torrentData: Data) -> Promise<String> {

        return Promise { seal in

            let headers = [
                "Content-Type": "multipart/form-data; charset=utf-8; boundary=__X_PAW_BOUNDARY__"
            ]

            // swiftlint:disable:next trailing_closure
            Manager.upload(multipartFormData: ({ multipartFormData in
                multipartFormData.append(torrentData, withName: "file")
            }), to: clientConfig.uploadURL, method: .post, headers: headers, encodingCompletion: { encodingResult in
                switch encodingResult {

                case .success(let request, _, _):
                    request.responseJSON(queue: self.utilityQueue) { response in
                        switch response.result {

                        case .success(let json):
                            if let json = json as? JSON,
                                let filePathArray = json["files"] as? [String],
                                let filePath = filePathArray.first {
                                seal.fulfill(filePath)
                            } else {
                                seal.reject(ClientError.uploadFailed)
                            }
                        case .failure(let error):
                            seal.reject(error)
                        }
                    }
                case .failure(let error): seal.reject(ClientError.unexpectedError(error.localizedDescription))
                }
            })
        }
    }

    func getTorrentInfo(torrent: Data) -> Promise<UploadedTorrentInfo> {
        return Promise { seal in
            firstly { upload(torrentData: torrent) }
                .done { fileName in
                    let parameters: Parameters = [
                        "id": arc4random(),
                        "method": "web.get_torrent_info",
                        "params": [fileName]
                    ]
                    self.Manager.request(self.clientConfig.url, method: .post,
                                         parameters: parameters, encoding: JSONEncoding.default)
                        .validate().responseJSON(queue: self.utilityQueue) { response in
                            switch response.result {
                            case .success(let json):
                                guard
                                    let dict = json as? JSON,
                                    let result = dict["result"] as? JSON,
                                    let info = UploadedTorrentInfo(json: result)
                                else {
                                    seal.reject(ClientError.unexpectedResponse)
                                    return
                                }
                                seal.fulfill(info)
                            case .failure(let error):
                                seal.reject(ClientError.unexpectedError(error.localizedDescription))
                            }
                    }

                }.catch { error in
                    seal.reject(error)
            }
        }
    }

    func getAddTorrentConfig() -> Promise<TorrentConfig> {
        let parameters: Parameters = [
            "id": arc4random(),
            "method": "core.get_config_values",
            "params": [[
                "add_paused",
                "compact_allocation",
                "download_location",
                "max_connections_per_torrent",
                "max_download_speed_per_torrent",
                "move_completed",
                "move_completed_path",
                "max_upload_slots_per_torrent",
                "max_upload_speed_per_torrent",
                "prioritize_first_last_pieces"
                ]]
        ]

        return Promise { seal in
            Manager.request(self.clientConfig.url, method: .post, parameters: parameters,
                            encoding: JSONEncoding.default)
                .validate().responseData(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let data):
                        do {
                            let response = try JSONDecoder()
                                .decode(DelugeResponse<TorrentConfig>.self, from: data)
                            seal.fulfill(response.result)
                        } catch let error {
                            print(error)
                            seal.reject(ClientError.torrentCouldNotBeParsed)
                        }

                    case .failure(let error):
                        seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }

    func setTorrentOptions(hash: String, options: [String: Any]) -> Promise<Void> {
        return Promise { seal in
            let params: Parameters = [
                "id": arc4random(),
                "method": "core.set_torrent_options",
                "params": [[hash], options]
            ]
            Manager.request(self.clientConfig.url, method: .post, parameters: params,
                            encoding: JSONEncoding.default)
                .validate().response { response in
                    if let error = response.error {
                        seal.reject(error)
                    } else {
                        seal.fulfill(())
                    }
            }
        }
    }

    func moveTorrent(hash: String, filepath: String) -> Promise<Void> {
        return Promise { seal in
            let params: Parameters = [
                "id": arc4random(),
                "method": "core.move_storage",
                "params": [[hash], filepath]
            ]

            Manager.request(self.clientConfig.url, method: .post, parameters: params, encoding: JSONEncoding.default)
                .validate().response { response in
                    if let error = response.error {
                        seal.reject(error)
                    } else {
                        seal.fulfill(())
                    }
            }
        }
    }

    func getHosts() -> Promise<[Host]> {
        let params: Parameters = [
            "id": arc4random(),
            "method": "web.get_hosts",
            "params": []
        ]

        return Promise { seal in
            Manager.request(self.clientConfig.url, method: .post, parameters: params, encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .failure(let error):
                        seal.reject(error)
                    case .success(let json):
                        guard
                            let json = json as? JSON,
                            let result = json["result"] as? [[Any]]
                        else {
                            seal.reject(ClientError.unexpectedResponse)
                            return
                        }
                        let hosts = result.compactMap { Host(jsonArray: $0) }
                        seal.fulfill(hosts)
                    }
            }

        }
    }

    func getHostStatus(for host: Host) -> Promise<HostStatus> {
        let params: Parameters = [
            "id": arc4random(),
            "method": "web.get_host_status",
            "params": [host.id]
        ]

        return Promise { seal in
            Manager.request(self.clientConfig.url, method: .post, parameters: params, encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .failure(let error):
                        seal.reject(error)
                    case .success(let json):
                        guard
                            let json = json as? JSON,
                            let result = json["result"] as? [Any],
                            let status = HostStatus(jsonArray: result)
                        else {
                            seal.reject(ClientError.unexpectedResponse)
                                return
                        }

                        seal.fulfill(status)
                    }
            }

        }
    }

    func connect(to host: Host) -> Promise<Void> {
        let params: Parameters = [
            "id": arc4random(),
            "method": "web.connect",
            "params": [host.id]
        ]

        return Promise { seal in
            Manager.request(clientConfig.url, method: .post, parameters: params, encoding: JSONEncoding.default)
                .validate().responseJSON(queue: utilityQueue) { response in
                    switch response.result {
                    case .failure(let error):
                        seal.reject(error)
                    case .success:
                        seal.fulfill(())
                    }
            }

        }

    }

    /**
     Gets the session status values `for keys`, these keys are taken
     from libtorrent's session status.
     See: [http://www.rasterbar.com/products/libtorrent/manual.html#status](http://www.rasterbar.com/products/libtorrent/manual.html#status)
     
     */
    @discardableResult
    func getSessionStatus() -> Promise<SessionStatus> {
        // swiftlint:disable:previous function_body_length
        return Promise { seal in
            let parameters: Parameters =
                [
                    "id": arc4random(),
                    "method": "core.get_session_status",
                    "params": [[
                        "has_incoming_connections",
                        "upload_rate",
                        "download_rate",
                        "total_download",
                        "total_upload",
                        "payload_upload_rate",
                        "payload_download_rate",
                        "total_payload_download",
                        "total_payload_upload",
                        "ip_overhead_upload_rate",
                        "ip_overhead_download_rate",
                        "total_ip_overhead_download",
                        "total_ip_overhead_upload",
                        "dht_upload_rate",
                        "dht_download_rate",
                        "total_dht_download",
                        "total_dht_upload",
                        "tracker_upload_rate",
                        "tracker_download_rate",
                        "total_tracker_download",
                        "total_tracker_upload",
                        "total_redundant_bytes",
                        "total_failed_bytes",
                        "num_peers",
                        "num_unchoked",
                        "allowed_upload_slots",
                        "up_bandwidth_queue",
                        "down_bandwidth_queue",
                        "up_bandwidth_bytes_queue",
                        "down_bandwidth_bytes_queue",
                        "optimistic_unchoke_counter",
                        "unchoke_counter",
                        "dht_nodes",
                        "dht_node_cache",
                        "dht_torrents",
                        "dht_total_allocations"
                    ]]
            ]

            Manager.request(clientConfig.url, method: .post, parameters: parameters, encoding: JSONEncoding.default)
                .validate().responseData(queue: utilityQueue) { response in
                    switch response.result {
                    case .success(let data):
                        do {
                            let torrent = try JSONDecoder().decode(DelugeResponse<SessionStatus>.self, from: data )
                            seal.fulfill(torrent.result)
                        } catch let error {
                            Logger.error(error)
                            seal.reject(ClientError.torrentCouldNotBeParsed)
                        }

                    case .failure(let error):
                        seal.reject(ClientError.unexpectedError(error.localizedDescription))
                    }
            }
        }
    }
} // swiftlint:disable:this file_length
