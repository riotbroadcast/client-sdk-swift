/*
 * Copyright 2024 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

@_implementationOnly import WebRTC

extension Room: SignalClientDelegate {
    func signalClient(_: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) async {
        log("canReconnect: \(canReconnect), reason: \(reason)")

        if canReconnect {
            // force .full for next reconnect
            engine._state.mutate { $0.nextReconnectMode = .full }
        } else {
            // Server indicates it's not recoverable
            await cleanUp(withError: LiveKitError.from(reason: reason))
        }
    }

    func signalClient(_: SignalClient, didUpdateSubscribedCodecs codecs: [Livekit_SubscribedCodec],
                      qualities: [Livekit_SubscribedQuality],
                      forTrackSid trackSid: String) async
    {
        log("[Publish/Backup] Qualities: \(qualities.map { String(describing: $0) }.joined(separator: ", ")), Codecs: \(codecs.map { String(describing: $0) }.joined(separator: ", "))")

        let trackSid = Track.Sid(from: trackSid)
        guard let publication = localParticipant.trackPublications[trackSid] as? LocalTrackPublication else {
            log("Received subscribed quality update for an unknown track", .warning)
            return
        }

        if !codecs.isEmpty {
            guard let videoTrack = publication.track as? LocalVideoTrack else { return }
            let missingSubscribedCodecs = (try? videoTrack._set(subscribedCodecs: codecs)) ?? []

            if !missingSubscribedCodecs.isEmpty {
                log("Missing codecs: \(missingSubscribedCodecs)")
                for missingSubscribedCodec in missingSubscribedCodecs {
                    do {
                        log("Publishing additional codec: \(missingSubscribedCodec)")
                        try await localParticipant.publish(additionalVideoCodec: missingSubscribedCodec, for: publication)
                    } catch {
                        log("Failed publishing additional codec: \(missingSubscribedCodec), error: \(error)", .error)
                    }
                }
            }

        } else {
            localParticipant._set(subscribedQualities: qualities, forTrackSid: trackSid)
        }
    }

    func signalClient(_: SignalClient, didReceiveConnectResponse connectResponse: SignalClient.ConnectResponse) async {
        if case let .join(joinResponse) = connectResponse {
            log("\(joinResponse.serverInfo)", .info)

            if e2eeManager != nil, !joinResponse.sifTrailer.isEmpty {
                e2eeManager?.keyProvider.setSifTrailer(trailer: joinResponse.sifTrailer)
            }

            _state.mutate {
                $0.sid = Room.Sid(from: joinResponse.room.sid)
                $0.name = joinResponse.room.name
                $0.metadata = joinResponse.room.metadata
                $0.isRecording = joinResponse.room.activeRecording
                $0.serverInfo = joinResponse.serverInfo

                localParticipant.updateFromInfo(info: joinResponse.participant)

                if !joinResponse.otherParticipants.isEmpty {
                    for otherParticipant in joinResponse.otherParticipants {
                        $0.updateRemoteParticipant(info: otherParticipant, room: self)
                    }
                }
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateRoom room: Livekit_Room) async {
        _state.mutate {
            $0.metadata = room.metadata
            $0.isRecording = room.activeRecording
            $0.maxParticipants = Int(room.maxParticipants)
            $0.numParticipants = Int(room.numParticipants)
            $0.numPublishers = Int(room.numPublishers)
        }
    }

    func signalClient(_: SignalClient, didUpdateSpeakers speakers: [Livekit_SpeakerInfo]) async {
        log("speakers: \(speakers)", .trace)

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {
                let participantSid = Participant.Sid(from: speaker.sid)
                guard let participant = participantSid == localParticipant.sid ? localParticipant : state.remoteParticipant(forSid: participantSid) else {
                    continue
                }

                participant._state.mutate {
                    $0.audioLevel = speaker.level
                    $0.isSpeaking = speaker.active
                }

                if speaker.active {
                    lastSpeakers[participantSid] = participant
                } else {
                    lastSpeakers.removeValue(forKey: participantSid)
                }
            }

            state.activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })

            return state.activeSpeakers
        }

        engine.executeIfConnected { [weak self] in
            guard let self else { return }

            self.delegates.notify(label: { "room.didUpdate speakers: \(speakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateConnectionQuality connectionQuality: [Livekit_ConnectionQualityInfo]) async {
        log("connectionQuality: \(connectionQuality)", .trace)

        for entry in connectionQuality {
            let participantSid = Participant.Sid(from: entry.participantSid)
            if participantSid == localParticipant.sid {
                // update for LocalParticipant
                localParticipant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            } else if let participant = _state.read({ $0.remoteParticipant(forSid: participantSid) }) {
                // udpate for RemoteParticipant
                participant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateRemoteMute trackSid: Track.Sid, muted: Bool) async {
        log("trackSid: \(trackSid) isMuted: \(muted)")

        guard let publication = localParticipant._state.trackPublications[trackSid] as? LocalTrackPublication else {
            // publication was not found but the delegate was handled
            return
        }

        do {
            if muted {
                try await publication.mute()
            } else {
                try await publication.unmute()
            }
        } catch {
            log("Failed to update mute for publication, error: \(error)", .error)
        }
    }

    func signalClient(_: SignalClient, didUpdateSubscriptionPermission subscriptionPermission: Livekit_SubscriptionPermissionUpdate) async {
        log("did update subscriptionPermission: \(subscriptionPermission)")

        let participantSid = Participant.Sid(from: subscriptionPermission.participantSid)
        let trackSid = Track.Sid(from: subscriptionPermission.trackSid)

        guard let participant = _state.read({ $0.remoteParticipant(forSid: participantSid) }),
              let publication = participant.trackPublications[trackSid] as? RemoteTrackPublication
        else {
            return
        }

        publication.set(subscriptionAllowed: subscriptionPermission.allowed)
    }

    func signalClient(_: SignalClient, didUpdateTrackStreamStates trackStates: [Livekit_StreamStateInfo]) async {
        log("did update trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        for update in trackStates {
            let participantSid = Participant.Sid(from: update.participantSid)
            let trackSid = Track.Sid(from: update.trackSid)

            // Try to find RemoteParticipant
            guard let participant = _state.read({ $0.remoteParticipant(forSid: participantSid) }) else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant._state.trackPublications[trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication._state.mutate { $0.streamState = update.state.toLKType() }
        }
    }

    func signalClient(_: SignalClient, didUpdateParticipants participants: [Livekit_ParticipantInfo]) async {
        log("participants: \(participants)")

        var disconnectedParticipantIdentities = [Participant.Identity]()
        var newParticipants = [RemoteParticipant]()

        _state.mutate {
            for info in participants {
                let infoIdentity = Participant.Identity(from: info.identity)

                if infoIdentity == localParticipant.identity {
                    localParticipant.updateFromInfo(info: info)
                    continue
                }

                if info.state == .disconnected {
                    // when it's disconnected, send updates
                    disconnectedParticipantIdentities.append(infoIdentity)
                } else {
                    let isNewParticipant = $0.remoteParticipants[infoIdentity] == nil
                    let participant = $0.updateRemoteParticipant(info: info, room: self)

                    if isNewParticipant {
                        newParticipants.append(participant)
                    } else {
                        participant.updateFromInfo(info: info)
                    }
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for identity in disconnectedParticipantIdentities {
                group.addTask {
                    do {
                        try await self._onParticipantDidDisconnect(identity: identity)
                    } catch {
                        self.log("Failed to process participant disconnection, error: \(error)", .error)
                    }
                }
            }
        }

        for participant in newParticipants {
            engine.executeIfConnected { [weak self] in
                guard let self else { return }

                self.delegates.notify(label: { "room.remoteParticipantDidConnect: \(participant)" }) {
                    $0.room?(self, participantDidConnect: participant)
                }
            }
        }
    }

    func signalClient(_: SignalClient, didUnpublishLocalTrack localTrack: Livekit_TrackUnpublishedResponse) async {
        log()

        let trackSid = Track.Sid(from: localTrack.trackSid)

        guard let publication = localParticipant._state.trackPublications[trackSid] as? LocalTrackPublication else {
            log("track publication not found", .warning)
            return
        }

        do {
            try await localParticipant.unpublish(publication: publication)
            log("Unpublished track(\(localTrack.trackSid)")
        } catch {
            log("Failed to unpublish track(\(localTrack.trackSid), error: \(error)", .warning)
        }
    }

    func signalClient(_: SignalClient, didUpdateConnectionState _: ConnectionState, oldState _: ConnectionState, disconnectError _: LiveKitError?) async {}

    func signalClient(_: SignalClient, didReceiveAnswer _: LKRTCSessionDescription) async {}

    func signalClient(_: SignalClient, didReceiveOffer _: LKRTCSessionDescription) async {}

    func signalClient(_: SignalClient, didReceiveIceCandidate _: LKRTCIceCandidate, target _: Livekit_SignalTarget) async {}

    func signalClient(_: SignalClient, didPublishLocalTrack _: Livekit_TrackPublishedResponse) async {}

    func signalClient(_: SignalClient, didUpdateToken _: String) async {}
}
