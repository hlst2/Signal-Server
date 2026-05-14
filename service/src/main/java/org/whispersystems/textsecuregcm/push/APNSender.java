/*
 * Copyright 2013 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */
package org.whispersystems.textsecuregcm.push;

import io.dropwizard.lifecycle.Managed;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;

/// No-op APNs sender for the server-private build, which has no outbound internet access
/// and therefore cannot reach api.push.apple.com. Returns an accepted result so the calling
/// `PushNotificationManager` doesn't mark the device token as unregistered.
public class APNSender implements Managed, PushNotificationSender {

  @Override
  public CompletableFuture<SendPushNotificationResult> sendNotification(final PushNotification notification) {
    return CompletableFuture.completedFuture(
        new SendPushNotificationResult(true, Optional.empty(), false, Optional.empty()));
  }

  @Override
  public void start() {
  }

  @Override
  public void stop() {
  }
}
