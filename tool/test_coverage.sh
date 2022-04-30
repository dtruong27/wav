#!/bin/bash

# Copyright 2022 The wav authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

dart pub global activate coverage
dart run --branch-coverage --pause-isolates-on-exit --disable-service-auth-codes --enable-vm-service=1234 test &
dart pub global run coverage:collect_coverage --wait-paused --uri=http://127.0.0.1:1234/ -o coverage.json --resume-isolates --scope-output=wav
dart pub global run coverage:format_coverage --branch-coverage --packages=.dart_tool/package_config.json --lcov -i coverage.json -o lcov.info
