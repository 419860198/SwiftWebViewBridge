//
//  SwiftWKWebViewBridge.swift
//  SwiftWebViewBridgeDemo
//
//  Created by zhangxiaobo on 2019/5/21.
//  Copyright © 2019 ShawnFoo. All rights reserved.
//

import WebKit
import UIKit

// MARK: - Custom Type

/// 1st param: responseData to JS
public typealias SWVBResponseCallBack = (NSDictionary) -> Void
/// 1st param: jsonData sent from JS; 2nd param: responseCallback for sending data back to JS
public typealias SWVBHandler = (AnyObject, @escaping SWVBResponseCallBack) -> Void
/// Dictionary to hold handlers for swift calling
public typealias SWVBHandlerDic = [String: SWVBHandler]
/// Dictionary to store the JS callback in the Swift side(Only pass the uniqueId to JS for the callback)
public typealias SWVBCallbackDic = [String: SWVBResponseCallBack]
public typealias SWVBMessage = [String: AnyObject]
public typealias SWVBData = [String: Any]

// MARK: - SwiftWKWebViewBridge

open class SwiftWKWebViewBridge: NSObject {

  // MARK: Constants

  fileprivate var kCustomProtocolScheme: String {
    return "swvbscheme" //lowercase!
  }

  fileprivate var kCustomProtocolHost: String {
    return "__SWVB_Host_MESSAGE__"
  }

  fileprivate var kJsCheckObjectDefinedCommand: String {
    return "typeof SwiftWebViewBridge == \'object\';"
  }

  fileprivate var kJsFetchMessagesCommand: String {
    return "SwiftWebViewBridge._fetchJSMessage();"
  }

  // MARK: Proporties

  public static var logging = true

  fileprivate weak var webView: WKWebView?
  fileprivate weak var oriDelegate: AnyObject?
  fileprivate var numOfLoadingRequests = 0

  // identity of the response callback
  fileprivate var uniqueId = 1
  // the queue stored messages called or sent before webView did finish load(js injection also finished in that function)
  fileprivate lazy var startupMessageQueue: [SWVBMessage]? = {
    return [SWVBMessage]()
  }()
  fileprivate var defaultHandler: SWVBHandler? {
    get {
      return self.messageHandlers["__kDefaultHandler__"]
    }
    set {
      if let handler = newValue {

        self.messageHandlers["__kDefaultHandler__"] = handler
      }
    }
  }
  // save the JS callback in the Swift side, only pass the uniqueId to JS for the callback
  fileprivate lazy var jsCallbacks: SWVBCallbackDic = SWVBCallbackDic()
  // handlers for JS calling
  fileprivate lazy var messageHandlers: SWVBHandlerDic = SWVBHandlerDic()


  // MARK: Factory / Initilizers

  /**
   Generate a bridge with associated webView and default handler to deal with messages from js

   - parameter webView: webView
   - parameter handler: default handler to deal with messages from js

   - returns: bridge
   */
  public class func bridge(_ webView: WKWebView, defaultHandler handler: SWVBHandler?) -> SwiftWKWebViewBridge {

    let bridge = SwiftWKWebViewBridge(webView: webView)

    // keep ref to original delegate
    bridge.oriDelegate = webView.navigationDelegate
    // replace it
    bridge.webView!.navigationDelegate = bridge
    bridge.defaultHandler = handler

    return bridge
  }

  fileprivate override init() {
    super.init()
  }

  fileprivate convenience init(webView: WKWebView) {
    self.init()
    self.webView = webView
  }
}

// MARK: - SwiftWKWebViewBridge + Message Manage

extension SwiftWKWebViewBridge {

  // MARK: Message Sent To JS

  /**
   Add message that will be sent to JS to Queue

   - parameter msg: message that will be sent to JS
   */
  fileprivate func addToMessageQueue(_ msg: SWVBMessage) {
    if nil != self.startupMessageQueue {
      self.startupMessageQueue!.append(msg)
    }
    else {
      self.dispatchMessage(msg)
    }
  }

  /**
   Sending every message(send data or call handler) that happened before UIWebView did finish all loadings to JS one by one
   */
  fileprivate func dispatchStartupMessageQueue() {
    if let queue = self.startupMessageQueue {
      for message in queue {
        self.dispatchMessage(message)
      }
      self.startupMessageQueue = nil
    }
  }

  /**
   Send message to JS. (Swift/ObjC call JS Handlers here)

   - parameter msg: message that will be sent to JS
   */
  fileprivate func dispatchMessage(_ msg: SWVBMessage) {

    if let jsonMsg: String = self.javascriptStylizedJSON(msg as AnyObject),
      let webView = self.webView
    {
      self.swvb_printLog(.SENT(jsonMsg as AnyObject))
      let jsCommand = "SwiftWebViewBridge._handleMessageFromSwift('\(jsonMsg)')"
      if Thread.isMainThread {
        webView.evaluateJavaScript(jsCommand, completionHandler: nil)
      }
      else {
        let _ =
        DispatchQueue.main.sync {
          webView.evaluateJavaScript(jsCommand, completionHandler: nil)
        }
      }
    }
    else {
      self.swvb_printLog(.ERROR("Swift Object Serialization Failed: \(msg)"))
    }
  }

  // MARK: Messages Sent From JS
  fileprivate func handleMessagesFromJS(_ jsonMessages: String) {

    guard let messages = self.deserilizeMessage(jsonMessages) as? Array<SWVBMessage> else {
      self.swvb_printLog(.ERROR("Failed to deserilize received msg from JS: \(jsonMessages)"))
      return
    }
    if 0 == messages.count {// filter empty messages' array
      return
    }

    self.swvb_printLog(.RCVD(messages as AnyObject))

    for swvbMsg in messages {
      // Swift callback(after JS finished designated handler called by Swift)
      if let responseId = swvbMsg["responseId"] as? String {
        if let callback = self.jsCallbacks[responseId] {
          if let responseData = swvbMsg["responseData"] != nil ? swvbMsg["responseData"] : NSNull() {
            callback(responseData as! NSDictionary)
          }
          self.jsCallbacks.removeValue(forKey: responseId)
        }
        else {
          self.swvb_printLog(.ERROR("No matching callback closure for: \(swvbMsg)"))
        }
      }
      else { // JS call Swift Handler
        let callback:SWVBResponseCallBack = {
          // if there is callbackId(that means JS has a callback), Swift send it back as responseId to JS so that JS can find and execute callback
          if let callbackId: String = swvbMsg["callbackId"] as? String {
            return { [unowned self] (responseData: AnyObject?) -> Void in
              let data:AnyObject = responseData != nil ? responseData! : NSNull()
              let msg: SWVBMessage = ["responseId": callbackId as AnyObject, "responseData": data]
              self.addToMessageQueue(msg)
            }
          }
          else {
            return { (data: AnyObject?) -> Void in
              // emtpy closure, make sure callback closure param is non-optional
            }
          }
        }()

        let handler:SWVBHandler? = { [unowned self] in
          if let handlerName = swvbMsg["handlerName"] as? String {
            return self.messageHandlers[handlerName]
          }
          return self.defaultHandler
          }()

        guard let handlerClosure = handler else {
          debugPrint("No handler for msg from JS: \(swvbMsg)..Please at least create a default handler when initializing the bridge = )")
          return
        }

        let msgData = swvbMsg["data"] != nil ? swvbMsg["data"] : NSNull()
        handlerClosure(msgData!, callback)
      }// else end
    }// for end
  }// func end

  // MARK: Swift Send Message To JS

  /**
   Sent data to JS simply
   */
  public func sendDataToJS(_ data: SWVBData) {
    self.callJSHandler(nil, params: data, responseCallback: nil)
  }

  /**
   Send data to JS with callback closure
   */
  public func sendDataToJS(_ data: SWVBData, responseCallback: SWVBResponseCallBack?) {
    self.callJSHandler(nil, params: data, responseCallback: responseCallback)
  }

  /**
   Call JavaScript handler

   - parameter handlerName:      handlerName should be identical to handler registered in JS. If this param is nil or no-matching name in JS, its params will be sent to JS defaultHandler
   - parameter params:           params(optional)
   - parameter responseCallback: callback(optional) will execute, after JS finished the matching handler
   */
  public func callJSHandler(_ handlerName: String?, params: SWVBData?, responseCallback: SWVBResponseCallBack?) {

    var message = SWVBMessage()
    if let params = params {
      message["data"] = params as AnyObject?
    }

    if let name = handlerName {
      message["handlerName"] = name as AnyObject?
    }

    if let callback = responseCallback {
      // pass this Id to JS, and then after JS finish its handler, this Id will pass back to Swift as responseId, so Swift can use it to find and execute the matching callback
      let callbackId = "cb_\(uniqueId)_Swift_\(Date().timeIntervalSince1970)"
      uniqueId += 1
      self.jsCallbacks[callbackId] = callback
      message["callbackId"] = callbackId as AnyObject?
    }

    self.addToMessageQueue(message)
  }

  // MARK: Rigister Handler For Message From JS

  /**
   Register a handler for JavaScript calling

   - parameter name:    handlerName
   - parameter handler: closure
   */
  public func registerHandlerForJS(handlerName name: String, handler:@escaping SWVBHandler) {
    self.messageHandlers[name] = handler
  }
}

// MARK: - SwiftWebViewBridge + WebViewDelegate

extension SwiftWKWebViewBridge: WKNavigationDelegate {

  // It's the only entrance where JavaScript can call Swift/ObjC handler or callback.Every URL loading in any frames will trigger this method

  public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url: URL = navigationAction.request.url {
      debugPrint(url)
      if self.isSchemeCorrect(url) && self.isHostCorrect(url) {
        // after JS trigger this method by loading URL, Swift needs to ask JS for messages by itself
        webView.evaluateJavaScript(self.kJsFetchMessagesCommand) { (data, err) in
          if let jsonMessages = data as? String{
            self.handleMessagesFromJS(jsonMessages)
          }else{
            print("Didn't fetch any message from JS!")
          }
        }
        decisionHandler(.cancel)
        return
      } else if let oriDelegate = self.oriDelegate as? WKNavigationDelegate {
        oriDelegate.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        return
      }
      decisionHandler(.allow)
    }else{
      decisionHandler(.cancel)
    }
  }

  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    self.numOfLoadingRequests += 1
    if let oriDelegate = self.oriDelegate as? WKNavigationDelegate {
      oriDelegate.webView?(webView, didStartProvisionalNavigation: navigation)
    }
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

    self.numOfLoadingRequests -= 1
    // after all frames have loaded, starting to inject js and dispatch unhanlded message

    let loadedAll = self.numOfLoadingRequests == 0
    webView.evaluateJavaScript(kJsCheckObjectDefinedCommand) { (data, err) in
      if let str = data as? NSNumber{
        let noDefinedBridge = str == 0
        if noDefinedBridge {
          webView.evaluateJavaScript(self.loadMinifiedJS(), completionHandler: nil)
          webView.evaluateJavaScript(self.kJsCheckObjectDefinedCommand, completionHandler: { (data, err) in
            if let str = data as? NSNumber {
              if str != 1 {
                print("Injection of js Failed!")
              }else{
                self.dispatchStartupMessageQueue()
              }
            }
          })
        }
      }
    }

    if let oriDelegate = self.oriDelegate as? WKNavigationDelegate {
      oriDelegate.webView?(webView, didFinish: navigation)
    }
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    self.numOfLoadingRequests -= 1
    if let oriDelegate = self.oriDelegate as? WKNavigationDelegate {
      oriDelegate.webView?(webView, didFail: navigation, withError: error)
    }
  }

  // MARK: URL Checking

  fileprivate func isSchemeCorrect(_ url: URL) -> Bool {
    return url.scheme == self.kCustomProtocolScheme;
  }

  fileprivate func isHostCorrect(_ url: URL) -> Bool {
    return url.host == self.kCustomProtocolHost;
  }
}

// MARK: - SwiftWebViewBridge + Nested Enum

extension SwiftWKWebViewBridge {

  fileprivate enum LogType: CustomStringConvertible {
    case ERROR(String), SENT(AnyObject), RCVD(AnyObject)

    var description: String {
      switch self {
      case let .ERROR(msg):
        return "LOGGING_ERROR: \(msg)"
      case let .SENT(msg):
        return "LOGGING_SENT: \(msg)"
      case let .RCVD(msg):
        return "LOGGING_RCVD: \(msg)"
      }
    }
  }

  // Print Log
  fileprivate func swvb_printLog(_ logType: LogType) {
    if SwiftWKWebViewBridge.logging {
      print(logType.description)
    }
  }
}

// MARK: - SwiftWKWebViewBridge + JSON Serilization

extension SwiftWKWebViewBridge {

  fileprivate func javascriptStylizedJSON(_ message: AnyObject) -> String? {
    if let jsonMsg = self.serilizeMessage(message) {
      let jsonStr = jsonMsg.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\'", with: "\\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

      //   \u2028: Line Seperator, 2029: Paragraph Seperator
      return jsonStr
    }
    return nil
  }

  fileprivate func serilizeMessage(_ message: AnyObject) -> String? {

    let jsonData: Data
    do {
      jsonData = try JSONSerialization.data(withJSONObject: message, options: JSONSerialization.WritingOptions())
    }
    catch let error as NSError {
      self.swvb_printLog(.ERROR(error.description))
      return nil
    }
    return String(data: jsonData, encoding: String.Encoding.utf8)
  }

  fileprivate func deserilizeMessage(_ message: String) -> AnyObject? {

    if let serilizedData = message.data(using: String.Encoding.utf8) {
      do {
        //  allow top-level objects that are not an instance of NSArray or NSDictionary
        let jsonObj = try JSONSerialization.jsonObject(with: serilizedData, options: .allowFragments)
        return jsonObj as AnyObject?
      }
      catch let error as NSError {
        self.swvb_printLog(.ERROR(error.description))
        return nil
      }
    }
    return nil
  }
}

// MARK: - SwiftWebViewBridge + JS Loading

extension SwiftWKWebViewBridge {

  fileprivate func loadMinifiedJS() -> String {
    return "(function(){function p(b){if(SwiftWebViewBridge._defaultHandler)throw Error(\"SwiftWebViewBridge.init called twice\");SwiftWebViewBridge._defaultHandler=b;b=d;d=null;for(var a=0;a<b.length;a++)k(b[a])}function q(){var b=JSON.stringify(f);f=[];return b}function r(b){d?d.push(b):k(b)}function t(b,a){l(null,b,a)}function l(b,a,c){b=b?{handlerName:b,data:a}:{data:a};c&&(a=\"cb_\"+u++ +\"_JS_\"+(new Date).getTime(),g[a]=c,b.callbackId=a);f.push(b);e.src=\"swvbscheme://__SWVB_Host_MESSAGE__\"}function v(b,a){m[b]=\na}function k(b){window.setTimeout(function(){var a=JSON.parse(b),c;if(a.responseId){if(c=g[a.responseId])c(a.responseData),delete g[a.responseId]}else{if(a.callbackId){var d=a.callbackId;c=function(a){f.push({responseId:d,responseData:a});e.src=\"swvbscheme://__SWVB_Host_MESSAGE__\"}}var h=SwiftWebViewBridge._defaultHandler;a.handlerName&&(h=m[a.handlerName]);if(h)try{h(a.data,c)}catch(w){\"undefined\"!=typeof console&&console.log(\"SwiftWebViewBridge: WARNING: javascript handler threw.\",a,w)}else onerror(\"No defaultHandler!\")}})}\nif(!window.SwiftWebViewBridge){var e,f=[],d=[],m={},g={},u=1;window.SwiftWebViewBridge={init:p,sendDataToSwift:t,registerHandlerForSwift:v,callSwiftHandler:l,_fetchJSMessage:q,_handleMessageFromSwift:r};e=document.createElement(\"iframe\");e.style.display=\"none\";e.src=\"swvbscheme://__SWVB_Host_MESSAGE__\";document.documentElement.appendChild(e);var n=document.createEvent(\"Events\");n.initEvent(\"SwiftWebViewBridgeReady\");document.dispatchEvent(n)}})();"
  }
}
