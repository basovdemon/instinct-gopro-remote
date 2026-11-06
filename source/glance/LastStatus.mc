import Toybox.Application;
import Toybox.Lang;
import Toybox.Time;

typedef StatusDictionary as Dictionary<Application.Storage.KeyType, Application.Storage.ValueType>;

// What the camera looked like the last time the app was connected to it. The app writes it,
// the glance reads it: the glance itself does not connect (that would wake the camera).
(:glance)
module LastStatus {

    const KEY = "lastStatus";

    // Only non-null values are stored; "time" is when this was last true (Unix seconds).
    function save(name as String?, battery as Number?, group as Number?, recording as Boolean) as Void {
        var value = {"rec" => recording, "time" => Time.now().value()} as StatusDictionary;
        if (name != null) {
            value["name"] = name;
        }
        if (battery != null) {
            value["battery"] = battery;
        }
        if (group != null) {
            value["group"] = group;
        }
        Application.Storage.setValue(KEY, value);
    }

    function load() as StatusDictionary? {
        var value = Application.Storage.getValue(KEY);
        return value instanceof Dictionary ? value as StatusDictionary : null;
    }
}
