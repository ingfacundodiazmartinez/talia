import UIKit
import Flutter
import Firebase
import UserNotifications
import GoogleMaps
import DeepAR

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()

    // Configure Google Maps with API key
    // TODO: Replace with your actual Google Maps API key
    GMSServices.provideAPIKey("AIzaSyDmaRq41cBttgeopHCXh1HvtvGSAegwo7E")

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    GeneratedPluginRegistrant.register(with: self)

    // Registrar plugin de DeepAR
    ArFiltersPlugin.register(with: registrar(forPlugin: "ArFiltersPlugin")!)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  override func application(_ application: UIApplication, 
                          didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Messaging.messaging().apnsToken = deviceToken
  }
}
