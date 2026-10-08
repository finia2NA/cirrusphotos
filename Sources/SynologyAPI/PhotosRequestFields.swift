/// The `additional` fields requested for every timeline item page.
///
/// The page cache key derives from the same list, so the request and its cache key
/// cannot drift apart.
public enum PhotosRequestFields {
    public static let pageAdditional = [
        "thumbnail", "resolution", "orientation", "video_convert",
        "video_meta", "address", "favorite", "exif", "gps",
    ]

    /// The `additional` fields for the whole-library location scan. Kept minimal:
    /// the scan only needs coordinates and the pin thumbnail descriptor.
    public static let locationScanAdditional = ["gps", "thumbnail"]
}
