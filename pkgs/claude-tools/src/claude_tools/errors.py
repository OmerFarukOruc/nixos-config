class Failed(Exception):
    pass


class HerdrError(Failed):
    def __init__(self, message: str, code: str | None = None):
        super().__init__(message)
        self.code = code


class NoProcess(Failed):
    pass
