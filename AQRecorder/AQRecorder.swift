
//
//  SVNRecorder.swift
//  WYNDR
//
//  Created by Aaron Dean Bikis on 5/24/17.
//  Copyright © 2017 7apps. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation

class SVNRecorder {
  
  // This implementation closely follows Apple's "Audio Queue Services Programming Guide".
  // See the guide for more information about audio queues and recording.
  
  var onPowerData: ((Float32) -> Void)?                   // callback for average dB power
  let session = AVAudioSession.sharedInstance()           // session for recording permission
  var isRecording = false                                 // state of recording
  var recordFile: AudioFileID?
  var recordPacket: Int64 = 0
  private(set) var format = AudioStreamBasicDescription() // audio data format specification
  
  
  private var queue: AudioQueueRef? = nil                          // opaque reference to an audio queue
  private var powerTimer: Timer?                                   // timer to invoke metering callback
  
  private let callback: AudioQueueInputCallback = {
    userData, queue, bufferRef, startTimeRef, numPackets, packetDescriptions in
    
    // parse `userData` as `SVNRecorder
    guard let userData = userData else { return }
    let audioRecorder = Unmanaged<SVNRecorder>.fromOpaque(userData).takeUnretainedValue()
    
    // dereference pointers
    let buffer = bufferRef.pointee
    //    let startTime = startTimeRef.pointee
    
    // calculate number of packets
    var numPackets = numPackets
    
    if numPackets > 0 {
      AudioFileWritePackets(audioRecorder.recordFile!,
                            false,
                            buffer.mAudioDataByteSize,
                            packetDescriptions,
                            audioRecorder.recordPacket,
                            &numPackets,
                            buffer.mAudioData)
      audioRecorder.recordPacket += Int64(numPackets)
    }
    // return early if recording is stopped
    guard audioRecorder.isRecording else {
      return
    }
    
    // enqueue buffer
    if let queue = audioRecorder.queue {
      AudioQueueEnqueueBuffer(queue, bufferRef, 0, nil)
    }
  }
  
  init() {
    var formatFlags = AudioFormatFlags()
    formatFlags |= kLinearPCMFormatFlagIsSignedInteger
    formatFlags |= kLinearPCMFormatFlagIsPacked
    self.format = AudioStreamBasicDescription(
      mSampleRate: 16000.0,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: formatFlags,
      mBytesPerPacket: UInt32(1*MemoryLayout<Int16>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(1*MemoryLayout<Int16>.stride),
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0)
  }
  
  
  //MARK - Record state
  private func prepareToRecord(with fileURL: URL) throws {
    // create recording queue
    let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    
    // get the property size
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
    
    try osStatus { AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &format) }
    
    try osStatus { AudioQueueNewInput(&format, callback, pointer, nil, nil, 0, &queue) }
    
    // ensure queue was set
    guard let queue = queue else {
      return
    }
    
    // set up format
    try osStatus { AudioQueueGetProperty(queue, kAudioQueueProperty_StreamDescription, &format, &formatSize) }
    
    try osStatus { AudioQueueGetProperty(queue, kAudioConverterCurrentOutputStreamDescription, &format, &formatSize) }
    
    var tempFile: AudioFileID?
    
    try osStatus { AudioFileCreateWithURL(fileURL as CFURL, // create the file to write to
      kAudioFileCAFType,
      &format, AudioFileFlags.eraseFile,
      &tempFile)
    }
    
    recordFile = tempFile
    // allocate and enqueue buffers
    let numBuffers = 3
    let bufferSize = deriveBufferSize(seconds: 0.5) // get the size of buffers
    for _ in 0..<numBuffers {
      let bufferRef = UnsafeMutablePointer<AudioQueueBufferRef?>.allocate(capacity: 1)
      try osStatus { AudioQueueAllocateBuffer(queue, bufferSize, bufferRef) }
      if let buffer = bufferRef.pointee {
        try osStatus { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
      }
    }
    
    // enable metering
    var metering: UInt32 = 1
    let meteringSize = UInt32(MemoryLayout<UInt32>.stride)
    let meteringProperty = kAudioQueueProperty_EnableLevelMetering
    AudioQueueSetProperty(queue, meteringProperty, &metering, meteringSize)
    
    // set metering timer to invoke callback
    powerTimer = Timer(
      timeInterval: 0.025,
      target: self,
      selector: #selector(samplePower),
      userInfo: nil,
      repeats: true
    )
    RunLoop.current.add(powerTimer!, forMode: RunLoopMode.commonModes)
  }
  
  
  func startRecording(toFileWith url: URL) throws {
    guard !isRecording else { return }
    try self.prepareToRecord(with: url)
    self.isRecording = true
    guard let queue = queue else { return }
    AudioQueueStart(queue, nil)
  }
  
  func stopRecording() throws {
    guard isRecording else { return }
    guard let queue = queue else { return }
    isRecording = false
    powerTimer?.invalidate()
    AudioQueueStop(queue, true)
    AudioQueueDispose(queue, false)
  }
  
  private func deriveBufferSize(seconds: Float64) -> UInt32 {
    guard let queue = queue else { return 0 }
    let maxBufferSize = UInt32(0x50000)
    var maxPacketSize = format.mBytesPerPacket
    if maxPacketSize == 0 {
      var maxVBRPacketSize = UInt32(MemoryLayout<UInt32>.stride)
      AudioQueueGetProperty(
        queue,
        kAudioQueueProperty_MaximumOutputPacketSize,
        &maxPacketSize,
        &maxVBRPacketSize
      )
    }
    
    let numBytesForTime = UInt32(format.mSampleRate * Float64(maxPacketSize) * seconds)
    let bufferSize = (numBytesForTime < maxBufferSize ? numBytesForTime : maxBufferSize)
    return bufferSize
  }
  
  
  @objc
  private func samplePower() {
    guard let queue = queue else { return }
    var meters = [AudioQueueLevelMeterState(mAveragePower: 0, mPeakPower: 0)]
    var metersSize = UInt32(meters.count * MemoryLayout<AudioQueueLevelMeterState>.stride)
    let meteringProperty = kAudioQueueProperty_CurrentLevelMeterDB
    let meterStatus = AudioQueueGetProperty(queue, meteringProperty, &meters, &metersSize)
    guard meterStatus == 0 else { return }
    onPowerData?(meters[0].mAveragePower)
  }
  
  func osStatus(_ osCall:() -> OSStatus) throws {
    let os = osCall()
    if os != noErr {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(os), userInfo: nil)
    }
  }

}
