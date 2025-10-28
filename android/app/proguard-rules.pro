# Keep DeepAR SDK classes and methods
-keep class ai.deepar.ar.** { *; }
-keepclassmembers class ai.deepar.ar.** { *; }
-dontwarn ai.deepar.ar.**

# Keep CameraX
-keep class androidx.camera.** { *; }
-keepclassmembers class androidx.camera.** { *; }

# Keep Agora RTC SDK
-keep class io.agora.**{*;}
-dontwarn io.agora.**
