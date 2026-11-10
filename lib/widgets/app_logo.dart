import 'package:flutter/material.dart';

import '../app_brand.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 40});

  final double height;

  @override
  Widget build(BuildContext context) => Image.asset(
    AppBrand.logoAsset,
    width: height * 4,
    height: height,
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
    semanticLabel: AppBrand.name,
  );
}
