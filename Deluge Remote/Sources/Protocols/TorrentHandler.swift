//
//  TorrentHandler.swift
//  Deluge Remote
//
//  Created by Rudy Bermudez on 12/12/20.
//  Copyright © 2020 Rudy Bermudez. All rights reserved.
//

import Foundation

enum TorrentType: String {
    case magnet = "Magnet Link"
    case file = "Torrent File"
}

enum TorrentData
{
    case magnet(URL)
    case file(Data)
    
    var type: TorrentType {
        switch self {
        case .magnet(_):
            return TorrentType.magnet
        case .file(_):
            return TorrentType.file
        }
    }
}

protocol TorrentHandler: AnyObject {
    func addTorrent(from data: TorrentData)
}
