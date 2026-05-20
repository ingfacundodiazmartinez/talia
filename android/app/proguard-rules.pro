# Keep CameraX
-keep class androidx.camera.** { *; }
-keepclassmembers class androidx.camera.** { *; }

# Keep Agora RTC SDK
-keep class io.agora.**{*;}
-dontwarn io.agora.**

# Facebook Audience Network
-dontwarn com.facebook.infer.annotation.Nullsafe$Mode
-dontwarn com.facebook.infer.annotation.Nullsafe
