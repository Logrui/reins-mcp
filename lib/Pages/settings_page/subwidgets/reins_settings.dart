import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:in_app_review/in_app_review.dart';

class ReinsSettings extends StatelessWidget {
  const ReinsSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    final bool isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Reins',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        ListTile(
          leading: Icon(Icons.rate_review),
          title: Text('Review Reins'),
          subtitle: Text('Share your feedback'),
          onTap: () async {
            if (isMobile &&
                defaultTargetPlatform == TargetPlatform.iOS &&
                await InAppReview.instance.isAvailable()) {
              InAppReview.instance.openStoreListing(appStoreId: "6739738501");
            } else {
              launchUrlString('https://github.com/ibrahimcetin/reins');
            }
          },
        ),
        ListTile(
          leading: Icon(Icons.share),
          title: Text('Share Reins'),
          subtitle: Text('Share Reins with your friends'),
          onTap: () {
            Share.share(
              'Check out Reins: https://github.com/ibrahimcetin/reins',
            );
          },
        ),
        if (isMobile)
          ListTile(
            leading: Icon(Icons.desktop_mac_outlined),
            title: Text('Try Desktop App'),
            subtitle: Text('Available on macOS and Windows'),
            onTap: () {
              launchUrlString('https://github.com/ibrahimcetin/reins/releases');
            },
          ),
        if (isDesktop)
          ListTile(
            leading: Icon(Icons.phone_iphone_outlined),
            title: Text('Try Mobile App'),
            subtitle: Text('Available on Android and iOS'),
            onTap: () {
              launchUrlString('https://github.com/ibrahimcetin/reins');
            },
          ),
        ListTile(
          leading: Icon(Icons.code),
          title: Text('Go to Source Code'),
          subtitle: Text('View on GitHub'),
          onTap: () {
            launchUrlString('https://github.com/ibrahimcetin/reins');
          },
        ),
        ListTile(
          leading: Icon(Icons.star),
          title: Text('Give a Star on GitHub'),
          subtitle: Text('Support the project'),
          onTap: () {
            launchUrlString('https://github.com/ibrahimcetin/reins');
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 5,
          children: [
            Icon(Icons.favorite, color: Colors.red, size: 16),
            Text("Thanks for using Reins!"),
          ],
        ),
      ],
    );
  }
}
