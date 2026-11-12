import AppKit
import CoreLocation
import SwiftUI

// MARK: - Weather (Open-Meteo, keyless)

final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()
    @Published var temp: Double?
    @Published var code = 0
    @Published var place = ""
    @Published var sunrise: Date?
    @Published var sunset: Date?
    private let lm = CLLocationManager()
    private var timer: Timer?

    func start() {
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
        if Prefs.double(Prefs.Key.weatherLat) != 0 { fetch() } else { lm.requestWhenInUseAuthorization(); lm.requestLocation() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.fetch() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        Prefs.set(l.coordinate.latitude, Prefs.Key.weatherLat)
        Prefs.set(l.coordinate.longitude, Prefs.Key.weatherLon)
        CLGeocoder().reverseGeocodeLocation(l) { p, _ in DispatchQueue.main.async { self.place = p?.first?.locality ?? "" } }
        fetch()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    func fetch() {
        let lat = Prefs.double(Prefs.Key.weatherLat), lon = Prefs.double(Prefs.Key.weatherLon)
        guard lat != 0 || lon != 0 else { return }
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=sunrise,sunset&timezone=auto&forecast_days=1")!
        URLSession.shared.dataTask(with: url) { d, _, _ in
            guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let cur = o["current"] as? [String: Any]
            let daily = o["daily"] as? [String: Any]
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let tz = o["timezone"] as? String { f.timeZone = TimeZone(identifier: tz) }
            DispatchQueue.main.async {
                self.temp = cur?["temperature_2m"] as? Double
                self.code = cur?["weather_code"] as? Int ?? 0
                self.sunrise = (daily?["sunrise"] as? [String])?.first.flatMap { f.date(from: $0) }
                self.sunset = (daily?["sunset"] as? [String])?.first.flatMap { f.date(from: $0) }
            }
        }.resume()
    }

    var symbol: String {
        switch code {
        case 0: return "sun.max.fill"
        case 1...3: return "cloud.sun.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
