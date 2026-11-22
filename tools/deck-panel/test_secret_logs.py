#!/usr/bin/env python3
"""Tests for check_secret_logs.py (#622): no print or log call in the panel's board code takes a password.
Run: python3 -I tools/deck-panel/test_secret_logs.py"""
import os, sys, unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_secret_logs


class FindTests(unittest.TestCase):
    def test_a_print_naming_a_password_is_found(self):
        src = 'void f() {\n    Serial.printf("pw %s\\n", g_saved.password);\n}\n'
        self.assertEqual(check_secret_logs.find(src), [2])

    def test_every_print_and_log_call_counts(self):
        for call in ("Serial.print(setup_password)", "Serial.println(g_setup_password)", "log_i(\"%s\", password)",
                     "ESP_LOGI(TAG, \"%s\", pw.password)", "Serial.write(credentials.password)"):
            self.assertEqual(check_secret_logs.find(call + ";\n"), [1], call)

    def test_a_call_over_several_lines_is_found_at_its_start(self):
        src = 'x();\nSerial.printf("a %s b %s\\n",\n              ssid,\n              password);\n'
        self.assertEqual(check_secret_logs.find(src), [2])

    def test_printing_the_name_or_mentioning_password_in_a_string_or_comment_is_fine(self):
        src = ('Serial.printf("joining \\"%s\\"\\n", g_saved.ssid);  // never the password\n'
               'Serial.println("deck panel: Wi-Fi password wrong?");\n')
        self.assertEqual(check_secret_logs.find(src), [])

    def test_the_panels_board_code_prints_no_password(self):
        here = os.path.dirname(os.path.abspath(__file__))
        self.assertEqual(check_secret_logs.check(os.path.join(here, "src")), [])


if __name__ == "__main__":
    unittest.main()
