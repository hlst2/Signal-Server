/*
 * Copyright 2013-2022 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.push;

import java.util.Optional;
import java.util.concurrent.CompletableFuture;

/// No-op FCM sender for the server-private build, which has no outbound internet access
/// and therefore cannot reach fcm.googleapis.com. Returns an accepted result so the calling
/// `PushNotificationManager` doesn't mark the device token as unregistered.
public class FcmSender implements PushNotificationSender {

  @Override
  public CompletableFuture<SendPushNotificationResult> sendNotification(PushNotification pushNotification) {
    return CompletableFuture.completedFuture(
        new SendPushNotificationResult(true, Optional.empty(), false, Optional.empty()));
  }
}
