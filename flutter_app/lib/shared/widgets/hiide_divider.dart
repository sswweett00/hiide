import 'package:flutter/material.dart';

class HiideDivider extends StatelessWidget {
  final double? height;
  final EdgeInsetsGeometry? margin;

  const HiideDivider({super.key, this.height, this.margin});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin ?? EdgeInsets.zero,
      height: height,
      child: Divider(
        height: height ?? 1,
        thickness: height ?? 1,
        indent: 0,
        endIndent: 0,
      ),
    );
  }
}
