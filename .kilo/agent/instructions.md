# Build Instructions

This project contains IBM i source code (ILE COBOL, RPGLE, DSPF) that CANNOT be built locally. The local environment is a standard Linux container and lacks the IBM i PASE tools (`cl`, `system`, `CRTSQLCBLI`, etc.).

- DO NOT attempt to run `make`, `make cbl`, or `make dspf` to verify your code changes.
- DO NOT attempt to compile the code locally.
- Rely solely on your internal syntax knowledge to write correct code, and leave the compilation to the user.
