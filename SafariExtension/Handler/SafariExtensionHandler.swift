// MARK: - SafariExtensionHandler.swift
import Foundation
import SafariServices
import os.log

// This is the native bridge for the Safari Web Extension.
// Even though Daisy uses URL schemes instead of native messaging,
// Safari requires this class to conform to NSExtensionRequestHandling.

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem else {
            os_log(.error, "Safari Web Extension request did not contain an NSExtensionItem")
            complete(context, status: "invalid-request")
            return
        }

        let message = item.userInfo?[SFExtensionMessageKey]
        os_log(.default, "Received message from Safari Web Extension: %@", String(describing: message))
        complete(context, status: "acknowledged")
    }

    private func complete(_ context: NSExtensionContext, status: String) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["status": status]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
