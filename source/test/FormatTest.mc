import Toybox.Lang;
import Toybox.Test;

(:test)
function formatDuration(logger as Logger) as Boolean {
    Test.assertEqual(Format.duration(0), "0:00");
    Test.assertEqual(Format.duration(65), "1:05");
    Test.assertEqual(Format.duration(3599), "59:59");
    Test.assertEqual(Format.duration(3600), "1:00:00");
    Test.assertEqual(Format.duration(3725), "1:02:05");
    return true;
}
