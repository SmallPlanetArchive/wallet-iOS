//
//  AddIssuerViewController.swift
//  wallet
//
//  Created by Chris Downie on 10/13/16.
//  Copyright © 2016 Learning Machine, Inc. All rights reserved.
//

import UIKit
import WebKit
import Blockcerts
import SystemConfiguration

class AddIssuerViewController: UIViewController, ManagedIssuerDelegate {
    private var inProgressRequest : CommonRequest?
    var delegate : AddIssuerViewControllerDelegate?
    let reachability = SCNetworkReachabilityCreateWithName(nil, "certificates.learningmachine.com")!
    
    var identificationURL: URL?
    var nonce: String?
    var managedIssuer: ManagedIssuer?
    var presentedModally = false
    var progressAlert: AlertViewController?
    
    @IBOutlet weak var scrollView : UIScrollView!
    @IBOutlet weak var issuerURLField: UITextView!
    @IBOutlet weak var nonceField : UITextView!
    @IBOutlet weak var submitButton : UIButton!
    
    var isLoading = false {
        didSet {
        }
    }
    
    init(identificationURL: URL? = nil, nonce: String? = nil) {
        self.identificationURL = identificationURL
        self.nonce = nonce
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = NSLocalizedString("Add an Issuer", comment: "Navigation title for the 'Add Issuer' form.")
        
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.backgroundColor = Style.Color.C3
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)

        issuerURLField.delegate = self
        issuerURLField.font = Style.Font.T3S
        issuerURLField.textColor = Style.Color.C3

        nonceField.delegate = self
        issuerURLField.font = Style.Font.T3S
        issuerURLField.textColor = Style.Color.C3

        loadDataIntoFields()
        stylize()
        
        // No need to unregister these. Thankfully.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow(notification:)), name: NSNotification.Name.UIKeyboardDidShow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide(notification:)), name: NSNotification.Name.UIKeyboardDidHide, object: nil)
    }
    
    func loadDataIntoFields() {
        issuerURLField.text = identificationURL?.absoluteString
        nonceField.text = nonce
        
        submitButton.isEnabled = nonceField.text.count > 0 && issuerURLField.text.count > 0
    }
    
    func saveDataIntoFields() {
        guard let urlString = issuerURLField.text, let url = URL(string: urlString) else {
            return
        }
        identificationURL = url
        nonce = nonceField.text
    }
    
    func stylize() { }

    @IBAction func addIssuerTapped(_ sender: Any) {
        Logger.main.info("Save issuer tapped")
        
        if !isNetworkReachable() {
            let alert = AlertViewController.createWarning(title: NSLocalizedString("No Network Connection", comment: "No network connection alert title"),
                                                          message: NSLocalizedString("Please check your network connection and try again.", comment: "No network connection alert message"))
            present(alert, animated: false, completion: nil)
            return
        }
        
        saveDataIntoFields()
        
        guard identificationURL != nil,
            nonce != nil else {
                return
        }
        
        identifyAndIntroduceIssuer(at: identificationURL!)
    }
    
    func isNetworkReachable() -> Bool {
        var flags = SCNetworkReachabilityFlags()
        SCNetworkReachabilityGetFlags(reachability, &flags)
        
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let canConnectAutomatically = flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)
        let canConnectWithoutUserInteraction = canConnectAutomatically && !flags.contains(.interventionRequired)
        
        return isReachable && (!needsConnection || canConnectWithoutUserInteraction)
    }

    @objc func cancelTapped(_ sender: UIBarButtonItem) {
        Logger.main.info("Cancel Add Issuer tapped")
        
        dismiss(animated: true, completion: nil)
    }
    
    func autoSubmitIfPossible() {
        loadDataIntoFields()
        
        let areAllFieldsFilled = identificationURL != nil && nonce != nil

        if areAllFieldsFilled {
            identifyAndIntroduceIssuer(at: identificationURL!)
        }
    }
    
    @objc func keyboardDidShow(notification: NSNotification) {
        guard let info = notification.userInfo,
            let keyboardRect = info[UIKeyboardFrameBeginUserInfoKey] as? CGRect else {
            return
        }

        let scrollInsets = UIEdgeInsets(top: 0, left: 0, bottom: keyboardRect.size.height, right: 0)
        scrollView.isScrollEnabled = true
        scrollView.contentInset = scrollInsets
        scrollView.scrollIndicatorInsets = scrollInsets
    }
    
    @objc func keyboardDidHide(notification: NSNotification) {
        scrollView.contentInset = .zero
        scrollView.scrollIndicatorInsets = .zero
    }
    
    func identifyAndIntroduceIssuer(at url: URL) {
        Logger.main.info("Starting process to identify and introduce issuer at \(url)")
        
        let progressAlert = AlertViewController.createProgress(title: NSLocalizedString("Adding Issuer", comment: "Title when adding issuer in progress"))
        present(progressAlert, animated: false, completion: nil)
        self.progressAlert = progressAlert
        
        cancelWebLogin()
        
        let targetRecipient = Recipient(givenName: "",
                                        familyName: "",
                                        identity: "",
                                        identityType: "email",
                                        isHashed: false,
                                        publicAddress: Keychain.shared.nextPublicAddress(),
                                        revocationAddress: nil)
        
        let managedIssuer = ManagedIssuer()
        self.managedIssuer = managedIssuer
        isLoading = true
        
        // LOADING IND
        
        managedIssuer.getIssuerIdentity(from: url) { [weak self] identifyError in
            guard identifyError == nil else {
                self?.isLoading = false
                
                var failureReason = NSLocalizedString("Something went wrong adding this issuer. Try again later.", comment: "Generic error for failure to add an issuer")
                
                switch(identifyError!) {
                case .invalidState(let reason):
                    // This is a developer error, so write it to the log so we can see it later.
                    Logger.main.fatal("Invalid ManagedIssuer state: \(reason)")
                    failureReason = NSLocalizedString("The app is in an invalid state. Please quit the app & relaunch. Then try again.", comment: "Invalid state error message when adding an issuer.")
                case .untrustworthyIssuer:
                    failureReason = NSLocalizedString("This issuer appears to have been tampered with. Please contact the issuer.", comment: "Error message when the issuer's data doesn't match the URL it's hosted at.")
                case .abortedIntroductionStep:
                    failureReason = NSLocalizedString("The request was aborted. Please try again.", comment: "Error message when an identification request is aborted")
                case .serverErrorDuringIdentification(let code, let message):
                    Logger.main.error("Error during issuer identification: \(code) \(message)")
                    failureReason = NSLocalizedString("The server encountered an error. Please try again.", comment: "Error message when an identification request sees a server error")
                case .serverErrorDuringIntroduction(let code, let message):
                    Logger.main.error("Error during issuer introduction: \(code) \(message)")
                    failureReason = NSLocalizedString("The server encountered an error. Please try again.", comment: "Error message when an identification request sees a server error")
                case .issuerInvalid(_, scope: .json):
                    failureReason = NSLocalizedString("We couldn't understand this Issuer's response. Please contact the Issuer.", comment: "Error message displayed when we see missing or invalid JSON in the response.")
                case .issuerInvalid(reason: .missing, scope: .property(let named)):
                    failureReason = String.init(format: NSLocalizedString("Issuer responded, but didn't include the \"%@\" property", comment: "Format string for an issuer response with a missing property. Variable is the property name that's missing."), named)
                case .issuerInvalid(reason: .invalid, scope: .property(let named)):
                    failureReason = String.init(format: NSLocalizedString("Issuer responded, but it contained an invalid property named \"%@\"", comment: "Format string for an issuer response with an invalid property. Variable is the property name that's invalid."), named)
                default: break
                }
                
                self?.showAddIssuerError(message: failureReason)

                return
            }
            
            Logger.main.info("Issuer identification at \(url) succeeded. Beginning introduction step.")
            
            if let nonce = self?.nonce {
                managedIssuer.delegate = self
                managedIssuer.introduce(recipient: targetRecipient, with: nonce) { introductionError in
                    guard introductionError == nil else {
                        self?.showAddIssuerError(withManagedIssuerError: introductionError!)
                        return
                    }
                    self?.dismissWebView()
                    self?.notifyAndDismiss(managedIssuer: managedIssuer)
                }
            } else {
                self?.showAddIssuerError(message: NSLocalizedString("We've encountered an error state when trying to talk to the issuer. Please try again.", comment: "Generic error when we've begun to introduce, but we don't have a nonce."))
            }
        }
    }
    
    @IBAction func cancelLoadingTapped(_ sender: Any) {
        Logger.main.info("Cancel Loading tapped.")
        
        managedIssuer?.abortRequests()
        isLoading = false
    }
    
    func notifyAndDismiss(managedIssuer: ManagedIssuer) {
        guard let progressAlert = progressAlert else { return }
        delegate?.added(managedIssuer: managedIssuer)
        
        DispatchQueue.main.async { [weak self] in
            
            let title = NSLocalizedString("Success!", comment: "Add issuers alert title")
            let message = NSLocalizedString("An issuer was added. Please check your issuers screen.", comment: "Add issuer alert message")
            
            progressAlert.setProgressAlert(false)
            progressAlert.set(title: title)
            progressAlert.set(message: message)
            progressAlert.icon = .success
            
            let okayButton = SecondaryButton(frame: .zero)
            okayButton.setTitle(NSLocalizedString("Okay", comment: "OK dismiss action"), for: .normal)
            okayButton.onTouchUpInside { [weak self] in
                progressAlert.dismiss(animated: false, completion: nil)
                
                if self?.presentedModally ?? true {
                    self?.presentingViewController?.dismiss(animated: true, completion: nil)
                } else {
                    self?.navigationController?.popViewController(animated: true)
                }
            }
            progressAlert.set(buttons: [okayButton])

            self?.isLoading = false
        }
    }
    
    func showAddIssuerError(withManagedIssuerError error: ManagedIssuerError) {
        var failureReason : String?
        
        switch error {
        case .invalidState(let reason):
            // This is a developer error, so write it to the log so we can see it later.
            Logger.main.fatal("Invalid ManagedIssuer state: \(reason)")
            failureReason = NSLocalizedString("The app is in an invalid state. Please quit the app & relaunch. Then try again.", comment: "Invalid state error message when adding an issuer.")
        case .untrustworthyIssuer:
            failureReason = NSLocalizedString("This issuer appears to have been tampered with. Please contact the issuer.", comment: "Error message when the issuer's data doesn't match the URL it's hosted at.")
        case .abortedIntroductionStep:
            failureReason = nil //NSLocalizedString("The request was aborted. Please try again.", comment: "Error message when an identification request is aborted")
        case .serverErrorDuringIdentification(let code, let message):
            Logger.main.error("Issuer identification failed with code: \(code) error: \(message)")
            failureReason = NSLocalizedString("The server encountered an error. Please try again.", comment: "Error message when an identification request sees a server error")
        case .serverErrorDuringIntroduction(let code, let message):
            Logger.main.error("Issuer introduction failed with code: \(code) error: \(message)")
            failureReason = NSLocalizedString("The server encountered an error. Please try again.", comment: "Error message when an identification request sees a server error")
        case .issuerInvalid(_, scope: .json):
            failureReason = NSLocalizedString("We couldn't understand this Issuer's response. Please contact the Issuer.", comment: "Error message displayed when we see missing or invalid JSON in the response.")
        case .issuerInvalid(reason: .missing, scope: .property(let named)):
            failureReason = String.init(format: NSLocalizedString("Issuer responded, but didn't include the \"%@\" property", comment: "Format string for an issuer response with a missing property. Variable is the property name that's missing."), named)
        case .issuerInvalid(reason: .invalid, scope: .property(let named)):
            failureReason = String.init(format: NSLocalizedString("Issuer responded, but it contained an invalid property named \"%@\"", comment: "Format string for an issuer response with an invalid property. Variable is the property name that's invalid."), named)
        case .authenticationFailure:
            Logger.main.error("Failed to authenticate the user to the issuer. Either because of a bad nonce or a failed web auth.")
            failureReason = NSLocalizedString("We couldn't authenticate you to the issuer. Double-check your one-time code and try again.", comment: "This error is presented when the user uses a bad nonce")
        case .genericError(let error, let data):
            var message : String?
            if data != nil {
                message = String(data: data!, encoding: .utf8)
            }
            Logger.main.error("Generic error during add issuer: \(error?.localizedDescription ?? "none"), data: \(message ?? "none")")
            failureReason = NSLocalizedString("Adding this issuer failed. Please try again", comment: "Generic error when adding an issuer.")
        default:
            failureReason = nil
        }
        
        if let message = failureReason {
            showAddIssuerError(message: message)
        }
    }
    
    func showAddIssuerError(message: String) {
        Logger.main.info("Add issuer failed with message: \(message)")
        guard let progressAlert = progressAlert else { return }
        
        DispatchQueue.main.async { [weak self] in
            
            let title = NSLocalizedString("Add Issuer Failed", comment: "Alert title when adding an issuer fails for any reason.")
            let cannedMessage = NSLocalizedString("There was an error adding this issuer. This can happen when a single-use invitation link is clicked more than once. Please check with the issuer and request a new invitation, if necessary.", comment: "Error message displayed when adding issuer failed")

            progressAlert.setProgressAlert(false)
            progressAlert.set(title: title)
            progressAlert.set(message: cannedMessage)
            progressAlert.icon = .failure
            
            let okayButton = SecondaryButton(frame: .zero)
            okayButton.setTitle(NSLocalizedString("Okay", comment: "OK dismiss action"), for: .normal)
            okayButton.onTouchUpInside {
                progressAlert.dismiss(animated: false, completion: nil)
            }
            progressAlert.set(buttons: [okayButton])
        
            self?.isLoading = false
        }
    }
    
    // MARK: - ManagedIssuerDelegate
    
    var webViewNavigationController: UINavigationController?
    
    func presentWebView(at url: URL, with navigationDelegate: WKNavigationDelegate) throws {
        Logger.main.info("Presenting the web view in the Add Issuer screen.")
        
        let webController = WebLoginViewController(requesting: url, navigationDelegate: navigationDelegate) { [weak self] in
            self?.cancelWebLogin()
            self?.dismissWebView()
        }
        let navigationController = UINavigationController(rootViewController: webController)
        navigationController.navigationBar.isTranslucent = false
        navigationController.navigationBar.backgroundColor = Style.Color.C3
        navigationController.navigationBar.barTintColor = Style.Color.C3
        webViewNavigationController = navigationController
        
        OperationQueue.main.addOperation {
            self.progressAlert?.dismiss(animated: false, completion: {
                self.present(navigationController, animated: true, completion: nil)
            })
        }
    }
    
    func dismissWebView() {
        OperationQueue.main.addOperation { [weak self] in
            self?.webViewNavigationController?.dismiss(animated: true, completion: nil)
        }
    }
    
    func cancelWebLogin() {
        managedIssuer?.abortRequests()
        isLoading = false
    }
}


struct ValidationOptions : OptionSet {
    let rawValue : Int
    
    static let required = ValidationOptions(rawValue: 1 << 0)
    static let url      = ValidationOptions(rawValue: 1 << 1)
    static let email    = ValidationOptions(rawValue: 1 << 2)
}

protocol AddIssuerViewControllerDelegate : class {
    func added(managedIssuer: ManagedIssuer)
}

extension AddIssuerViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            if textView === issuerURLField {
                nonceField.becomeFirstResponder()
            } else {
                textView.resignFirstResponder()
            }
            return false
        }
        return true
    }
    
    func textViewDidChange(_ textView: UITextView) {
        submitButton.isEnabled = nonceField.text.count > 0 && issuerURLField.text.count > 0
    }
    
}
