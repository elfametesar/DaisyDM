// MARK: - SafariExtensionHandler.swift
import Foundation
import SafariServices
import os.log

// This is the native bridge for the Safari Web Extension.
// Even though Dispatch uses URL Schemes instead of native messaging, 
// Safari strictly requires this class to exist and conform to NSExtensionRequestHandling.

@objc(SafariWebExtensionHandler)
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems[0] as! NSExtensionItem
        let message = item.userInfo?[SFExtensionMessageKey]
        
        os_log(.default, "Received message from Safari Web Extension: %@", String(describing: message))
        
        let response = NSExtensionItem()
        response.userInfo = [ SFExtensionMessageKey: [ "status": "acknowledged" ] ]
        
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
