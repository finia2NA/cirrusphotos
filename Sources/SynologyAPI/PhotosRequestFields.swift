/// The `additional` fields requested for every timeline item page.
///
/// The page cache key derives from the same list, so the request and its cache key
/// cannot drift apart.
public enum PhotosRequestFields {
    public static let pageAdditional = [
        "thumbnail", "resolution", "orientation", "video_convert",
        "video_meta", "address", "favorite", "exif",
    ]
}
