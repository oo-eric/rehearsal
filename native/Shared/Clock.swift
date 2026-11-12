import Darwin

/// One monotonic clock for everything that keeps time: the beat timeline, the audio
/// scheduler, and the linked-device clock offsets. Milliseconds, like the web app's
/// performance.now(), so sync messages stay wire-compatible with the old builds.
///
/// It is mach_absolute_time, which is also what Core Audio stamps buffers with
/// (AudioTimeStamp.mHostTime), so a beat time converts straight into a sample position.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func now() -> Double { ms(hostTime: mach_absolute_time()) }

    static func ms(hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    /// Wall clock (ms since 1970), for "who changed something last" across devices.
    static func wall() -> Double {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
    }
}
