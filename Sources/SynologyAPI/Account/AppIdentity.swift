/// The app's bundle identifier, also used as the logging subsystem, the Keychain service and
/// the distribution build's Application Support folder name. Development builds end in `.dev`,
/// so their preferences, Keychain items and logs stay apart from an installed distribution build.
public enum AppIdentity {
    #if CIRRUS_DISTRIBUTION
    public static let bundleIdentifier = "io.github.finia2na.cirrusphotos"
    #else
    public static let bundleIdentifier = "io.github.finia2na.cirrusphotos.dev"
    #endif
}
