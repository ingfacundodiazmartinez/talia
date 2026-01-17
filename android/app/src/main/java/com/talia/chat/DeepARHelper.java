package com.talia.chat;

import ai.deepar.ar.AREventListener;
import ai.deepar.ar.ARErrorType;
import ai.deepar.ar.DeepAR;
import android.graphics.Bitmap;
import java.lang.reflect.Proxy;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;

public class DeepARHelper {

    public interface EventCallback {
        void onEvent(String event, java.util.Map<String, Object> data);
    }

    public static void setAREventListener(DeepAR deepAR, final EventCallback callback) {
        // Usar reflection/proxy para evitar problemas con tipos que Kotlin no puede resolver
        ClassLoader classLoader = AREventListener.class.getClassLoader();

        AREventListener listener = (AREventListener) Proxy.newProxyInstance(
            classLoader,
            new Class[] { AREventListener.class },
            new InvocationHandler() {
                @Override
                public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                    String methodName = method.getName();

                    switch (methodName) {
                        case "frameAvailable":
                            // Frame disponible - no loggeamos para evitar spam
                            break;

                        case "screenshotTaken":
                            if (args != null && args.length > 0) {
                                Bitmap bitmap = (Bitmap) args[0];
                                java.util.HashMap<String, Object> data = new java.util.HashMap<>();
                                data.put("success", bitmap != null);
                                data.put("bitmap", bitmap); // IMPORTANTE: Pasar el bitmap al callback
                                callback.onEvent("screenshotTaken", data);
                            }
                            break;

                        case "videoRecordingStarted":
                            java.util.HashMap<String, Object> startData = new java.util.HashMap<>();
                            startData.put("success", true);
                            callback.onEvent("recordingStarted", startData);
                            break;

                        case "videoRecordingFinished":
                            java.util.HashMap<String, Object> finishData = new java.util.HashMap<>();
                            finishData.put("success", true);
                            callback.onEvent("recordingStopped", finishData);
                            break;

                        case "videoRecordingFailed":
                            java.util.HashMap<String, Object> failData = new java.util.HashMap<>();
                            failData.put("message", "Video recording failed");
                            callback.onEvent("error", failData);
                            break;

                        case "videoRecordingPrepared":
                            // Grabación preparada
                            break;

                        case "shutdownFinished":
                            // Shutdown finalizado
                            break;

                        case "initialized":
                            java.util.HashMap<String, Object> initData = new java.util.HashMap<>();
                            initData.put("success", true);
                            callback.onEvent("initialized", initData);
                            break;

                        case "faceVisibilityChanged":
                            // Cara visible
                            break;

                        case "imageVisibilityChanged":
                            // Imagen visible
                            break;

                        case "error":
                            if (args != null && args.length >= 2) {
                                ARErrorType errorType = (ARErrorType) args[0];
                                String message = (String) args[1];
                                java.util.HashMap<String, Object> errorData = new java.util.HashMap<>();
                                errorData.put("type", errorType != null ? errorType.toString() : "UNKNOWN");
                                errorData.put("message", message != null ? message : "Unknown error");
                                callback.onEvent("error", errorData);
                            }
                            break;

                        case "effectSwitched":
                            if (args != null && args.length > 0) {
                                String effectName = (String) args[0];
                                java.util.HashMap<String, Object> effectData = new java.util.HashMap<>();
                                effectData.put("filterPath", effectName != null ? effectName : "");
                                callback.onEvent("filterChanged", effectData);
                            }
                            break;
                    }

                    return null;
                }
            }
        );

        deepAR.setAREventListener(listener);
    }
}
