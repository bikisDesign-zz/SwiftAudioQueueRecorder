//
//  ViewController.swift
//  AQRecorder
//
//  Created by Aaron Dean Bikis on 5/26/17.
//  Copyright © 2017 7apps. All rights reserved.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
  private lazy var tempFilePath: URL = self.getDocumentsDirectory().appendingPathComponent("temp.caf")
  private lazy var audioSession: AVAudioSession = AVAudioSession.sharedInstance() // the global audio session instance
  private var recorder: SVNRecorder!

  override func viewDidLoad() {
    super.viewDidLoad()
    setupRecorder()
    startRecording()
  }
  
  func setupRecorder()  {
    do {
    recorder = SVNRecorder()
    try audioSession.setCategory(AVAudioSessionCategoryRecord) // set session and request access to microphone
    try audioSession.setActive(true)
    audioSession.requestRecordPermission({ (isAllowed) in
      guard isAllowed else {
        fatalError("permission declined")
      }
    })
    } catch {
      fatalError("couldn't init recorder")
    }
  }
  
  func startRecording() {
    do {
      try recorder?.startRecording(toFileWith: tempFilePath)
    } catch {
      fatalError("error recording")
    }
  }
  
  
  func stopRecording(shouldPlay setupPlayback: Bool) {
    do {
      try recorder?.stopRecording()
    } catch {
      print("error stopping recording")
      return
    }
  }

  private func getDocumentsDirectory() -> URL {
    return try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  }
}
