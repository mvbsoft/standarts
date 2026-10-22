import unittest

import app


class AppTest(unittest.TestCase):
    def test_version(self):
        self.assertGreater(app.VERSION, 0)


if __name__ == "__main__":
    unittest.main()
