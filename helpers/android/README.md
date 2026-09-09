# Android helper build

Until this native project owns its Gradle wrapper, use the already downloaded repository wrapper:

```sh
../../apps/device_companion/android/gradlew -p . assembleDebug
```

The release workflow will embed the resulting versioned APK in the Mac application. Developers using
the product do not run this command or install the APK manually.
