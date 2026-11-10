import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) => writeResponseData(
      data,
      testOutputFilename: 'low_end_tv_results',
      destinationDirectory:
          Platform.environment['LOW_END_TV_RESULTS_DIR'] ?? 'build/low_end_tv',
    ),
  );
}
