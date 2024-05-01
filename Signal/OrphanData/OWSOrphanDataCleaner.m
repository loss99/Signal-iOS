//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "OWSOrphanDataCleaner.h"
#import "OWSProfileManager.h"
#import "Signal-Swift.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalServiceKit/AppReadiness.h>
#import <SignalServiceKit/OWSFileSystem.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <SignalServiceKit/TSAttachmentStream.h>
#import <SignalServiceKit/TSInteraction.h>
#import <SignalServiceKit/TSMessage.h>
#import <SignalServiceKit/TSQuotedMessage.h>
#import <SignalServiceKit/TSThread.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const OWSOrphanDataCleaner_LastCleaningVersionKey = @"OWSOrphanDataCleaner_LastCleaningVersionKey";
NSString *const OWSOrphanDataCleaner_LastCleaningDateKey = @"OWSOrphanDataCleaner_LastCleaningDateKey";

typedef void (^OrphanDataBlock)(OWSOrphanData *);

@implementation OWSOrphanDataCleaner

// This method finds (but does not delete):
//
// * Orphan TSInteractions (with no thread).
// * Orphan TSAttachments (with no message).
// * Orphan attachment files (with no corresponding TSAttachment).
// * Orphan profile avatars.
// * Temporary files (all).
//
// It also finds (we don't clean these up).
//
// * Missing attachment files (cannot be cleaned up).
//   These are attachments which have no file on disk.  They should be extremely rare -
//   the only cases I have seen are probably due to debugging.
//   They can't be cleaned up - we don't want to delete the TSAttachmentStream or
//   its corresponding message.  Better that the broken message shows up in the
//   conversation view.
+ (void)findOrphanDataWithRetries:(NSInteger)remainingRetries
                          success:(OrphanDataBlock)success
                          failure:(dispatch_block_t)failure
{
    if (remainingRetries < 1) {
        OWSLogInfo(@"Aborting orphan data search. No more retries.");
        dispatch_async(self.workQueue, ^{ failure(); });
        return;
    }

    OWSLogInfo(@"Enqueuing an orphan data search. Remaining retries: %ld", (long)remainingRetries);

    // Wait until the app is active...
    [CurrentAppContext() runNowOrWhenMainAppIsActive:^{
        // ...but perform the work off the main thread.
        OWSBackgroundTask *_Nullable backgroundTask =
            [OWSBackgroundTask backgroundTaskWithLabelStr:__PRETTY_FUNCTION__];
        dispatch_async(self.workQueue, ^{
            OWSOrphanData *_Nullable orphanData = [self findOrphanDataSync];
            if (orphanData) {
                success(orphanData);
            } else {
                [self findOrphanDataWithRetries:remainingRetries - 1 success:success failure:failure];
            }
            [backgroundTask endBackgroundTask];
        });
    }];
}

// Returns nil on failure, usually indicating that the search
// aborted due to the app resigning active.  This method is extremely careful to
// abort if the app resigns active, in order to avoid 0xdead10cc crashes.
+ (nullable OWSOrphanData *)findOrphanDataSync
{
    __block BOOL shouldAbort = NO;

    NSString *legacyAttachmentsDirPath = TSAttachmentStream.legacyAttachmentsDirPath;
    NSString *sharedDataAttachmentsDirPath = TSAttachmentStream.sharedDataAttachmentsDirPath;
    NSSet<NSString *> *_Nullable legacyAttachmentFilePaths = [self filePathsInDirectorySafe:legacyAttachmentsDirPath];
    if (!legacyAttachmentFilePaths || !self.isMainAppAndActive) {
        return nil;
    }
    NSSet<NSString *> *_Nullable sharedDataAttachmentFilePaths =
        [self filePathsInDirectorySafe:sharedDataAttachmentsDirPath];
    if (!sharedDataAttachmentFilePaths || !self.isMainAppAndActive) {
        return nil;
    }

    NSString *legacyProfileAvatarsDirPath = OWSUserProfile.legacyProfileAvatarsDirPath;
    NSString *sharedDataProfileAvatarsDirPath = OWSUserProfile.sharedDataProfileAvatarsDirPath;
    NSSet<NSString *> *_Nullable legacyProfileAvatarsFilePaths =
        [self filePathsInDirectorySafe:legacyProfileAvatarsDirPath];
    if (!legacyProfileAvatarsFilePaths || !self.isMainAppAndActive) {
        return nil;
    }
    NSSet<NSString *> *_Nullable sharedDataProfileAvatarFilePaths =
        [self filePathsInDirectorySafe:sharedDataProfileAvatarsDirPath];
    if (!sharedDataProfileAvatarFilePaths || !self.isMainAppAndActive) {
        return nil;
    }

    NSSet<NSString *> *_Nullable allGroupAvatarFilePaths =
        [self filePathsInDirectorySafe:TSGroupModel.avatarsDirectory.path];
    if (!allGroupAvatarFilePaths || !self.isMainAppAndActive) {
        return nil;
    }

    NSString *stickersDirPath = StickerManager.cacheDirUrl.path;
    NSSet<NSString *> *_Nullable allStickerFilePaths = [self filePathsInDirectorySafe:stickersDirPath];
    if (!allStickerFilePaths || !self.isMainAppAndActive) {
        return nil;
    }

    NSMutableSet<NSString *> *allOnDiskFilePaths = [NSMutableSet new];
    [allOnDiskFilePaths unionSet:legacyAttachmentFilePaths];
    [allOnDiskFilePaths unionSet:sharedDataAttachmentFilePaths];
    [allOnDiskFilePaths unionSet:legacyProfileAvatarsFilePaths];
    [allOnDiskFilePaths unionSet:sharedDataProfileAvatarFilePaths];
    [allOnDiskFilePaths unionSet:allGroupAvatarFilePaths];
    [allOnDiskFilePaths unionSet:allStickerFilePaths];
    // TODO: Badges?

    // This should be redundant, but this will future-proof us against
    // ever accidentally removing the GRDB databases during
    // orphan clean up.
    NSString *grdbPrimaryDirectoryPath =
        [GRDBDatabaseStorageAdapter databaseDirUrlWithDirectoryMode:DirectoryModePrimary].path;
    NSString *grdbHotswapDirectoryPath =
        [GRDBDatabaseStorageAdapter databaseDirUrlWithDirectoryMode:DirectoryModeHotswapLegacy].path;
    NSString *grdbTransferDirectoryPath = nil;
    if (GRDBDatabaseStorageAdapter.hasAssignedTransferDirectory &&
        [TSAccountManagerObjcBridge isTransferInProgressWithMaybeTransaction]) {
        grdbTransferDirectoryPath =
            [GRDBDatabaseStorageAdapter databaseDirUrlWithDirectoryMode:DirectoryModeTransfer].path;
    }

    NSMutableSet<NSString *> *databaseFilePaths = [NSMutableSet new];
    for (NSString *filePath in allOnDiskFilePaths) {
        if ([filePath hasPrefix:grdbPrimaryDirectoryPath]) {
            OWSLogInfo(@"Protecting database file: %@", filePath);
            [databaseFilePaths addObject:filePath];
        } else if ([filePath hasPrefix:grdbHotswapDirectoryPath]) {
            OWSLogInfo(@"Protecting database hotswap file: %@", filePath);
            [databaseFilePaths addObject:filePath];
        } else if (grdbTransferDirectoryPath && [filePath hasPrefix:grdbTransferDirectoryPath]) {
            OWSLogInfo(@"Protecting database hotswap file: %@", filePath);
            [databaseFilePaths addObject:filePath];
        }
    }
    [allOnDiskFilePaths minusSet:databaseFilePaths];

    __block NSSet<NSString *> *profileAvatarFilePaths;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        profileAvatarFilePaths = [OWSProfileManager allProfileAvatarFilePathsWithTransaction:transaction];
    }];

    __block NSSet<NSString *> *groupAvatarFilePaths;
    __block NSError *groupAvatarFilePathError;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        groupAvatarFilePaths = [TSGroupModel allGroupAvatarFilePathsWithTransaction:transaction
                                                                              error:&groupAvatarFilePathError];
    }];

    if (groupAvatarFilePathError) {
        OWSFailDebug(@"Failed to query group avatar file paths %@", groupAvatarFilePathError);
        return nil;
    }

    if (!self.isMainAppAndActive) {
        return nil;
    }

    NSSet<NSString *> *voiceMessageDraftOrphanedPaths = [self findOrphanedVoiceMessageDraftPaths];

    if (!self.isMainAppAndActive) {
        return nil;
    }

    NSSet<NSString *> *wallpaperOrphanedPaths = [self findOrphanedWallpaperPaths];

    if (!self.isMainAppAndActive) {
        return nil;
    }

    // Attachments
    __block int attachmentStreamCount = 0;
    NSMutableSet<NSString *> *allAttachmentFilePaths = [NSMutableSet new];
    NSMutableSet<NSString *> *allAttachmentIds = [NSMutableSet new];
    // Reactions
    NSMutableSet<NSString *> *allReactionIds = [NSMutableSet new];
    // Mentions
    NSMutableSet<NSString *> *allMentionIds = [NSMutableSet new];
    // Threads
    __block NSSet *threadIds;
    // Messages
    NSMutableSet<NSString *> *orphanInteractionIds = [NSMutableSet new];
    NSMutableSet<NSString *> *allMessageAttachmentIds = [NSMutableSet new];
    NSMutableSet<NSString *> *allStoryAttachmentIds = [NSMutableSet new];
    NSMutableSet<NSString *> *allMessageReactionIds = [NSMutableSet new];
    NSMutableSet<NSString *> *allMessageMentionIds = [NSMutableSet new];
    // Stickers
    NSMutableSet<NSString *> *activeStickerFilePaths = [NSMutableSet new];
    __block BOOL hasOrphanedPacksOrStickers = NO;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        [TSAttachmentStream
            anyEnumerateWithTransaction:transaction
                                batched:YES
                                  block:^(TSAttachment *attachment, BOOL *stop) {
                                      if (!self.isMainAppAndActive) {
                                          shouldAbort = YES;
                                          *stop = YES;
                                          return;
                                      }
                                      if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
                                          return;
                                      }
                                      [allAttachmentIds addObject:attachment.uniqueId];

                                      TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;
                                      attachmentStreamCount++;
                                      NSString *_Nullable filePath = [attachmentStream originalFilePath];
                                      if (filePath) {
                                          [allAttachmentFilePaths addObject:filePath];
                                      } else {
                                          OWSFailDebug(@"attachment has no file path.");
                                      }

                                      [allAttachmentFilePaths
                                          addObjectsFromArray:attachmentStream.allSecondaryFilePaths];
                                  }];

        if (shouldAbort) {
            return;
        }

        threadIds = [NSSet setWithArray:[TSThread anyAllUniqueIdsWithTransaction:transaction]];

        NSMutableSet<NSString *> *allInteractionIds = [NSMutableSet new];
        [TSInteraction
            anyEnumerateWithTransaction:transaction
                                batched:YES
                                  block:^(TSInteraction *interaction, BOOL *stop) {
                                      if (!self.isMainAppAndActive) {
                                          shouldAbort = YES;
                                          *stop = YES;
                                          return;
                                      }
                                      if (interaction.uniqueThreadId.length < 1
                                          || ![threadIds containsObject:interaction.uniqueThreadId]) {
                                          [orphanInteractionIds addObject:interaction.uniqueId];
                                      }

                                      [allInteractionIds addObject:interaction.uniqueId];
                                      if (![interaction isKindOfClass:[TSMessage class]]) {
                                          return;
                                      }

                                      TSMessage *message = (TSMessage *)interaction;
                                      [allMessageAttachmentIds
                                          addObjectsFromArray:[OWSOrphanDataCleaner legacyAttachmentUniqueIds:message]];
                                  }];

        if (shouldAbort) {
            return;
        }

        [OWSReaction anyEnumerateObjcWithTransaction:transaction
                                             batched:YES
                                               block:^(OWSReaction *reaction, BOOL *stop) {
                                                   if (!self.isMainAppAndActive) {
                                                       shouldAbort = YES;
                                                       *stop = YES;
                                                       return;
                                                   }
                                                   if (![reaction isKindOfClass:[OWSReaction class]]) {
                                                       return;
                                                   }
                                                   [allReactionIds addObject:reaction.uniqueId];
                                                   if ([allInteractionIds containsObject:reaction.uniqueMessageId]) {
                                                       [allMessageReactionIds addObject:reaction.uniqueId];
                                                   }
                                               }];

        if (shouldAbort) {
            return;
        }

        [TSMention anyEnumerateObjcWithTransaction:transaction
                                           batched:YES
                                             block:^(TSMention *mention, BOOL *stop) {
                                                 if (!self.isMainAppAndActive) {
                                                     shouldAbort = YES;
                                                     *stop = YES;
                                                     return;
                                                 }
                                                 if (![mention isKindOfClass:[TSMention class]]) {
                                                     return;
                                                 }
                                                 [allMentionIds addObject:mention.uniqueId];
                                                 if ([allInteractionIds containsObject:mention.uniqueMessageId]) {
                                                     [allMessageMentionIds addObject:mention.uniqueId];
                                                 }
                                             }];

        if (shouldAbort) {
            return;
        }

        [StoryMessage anyEnumerateObjcWithTransaction:transaction
                                              batched:YES
                                                block:^(StoryMessage *message, BOOL *stop) {
                                                    if (!self.isMainAppAndActive) {
                                                        shouldAbort = YES;
                                                        *stop = YES;
                                                        return;
                                                    }
                                                    if (![message isKindOfClass:[StoryMessage class]]) {
                                                        return;
                                                    }
                                                    NSString *attachmentUniqueId =
                                                        [OWSOrphanDataCleaner legacyAttachmentUniqueId:message];
                                                    if (attachmentUniqueId != nil) {
                                                        [allStoryAttachmentIds addObject:attachmentUniqueId];
                                                    }
                                                }];

        if (shouldAbort) {
            return;
        }

        NSArray<NSString *> *jobRecordAttachmentIds = [self findJobRecordAttachmentIdsWithTransaction:transaction];
        if (jobRecordAttachmentIds == nil) {
            shouldAbort = YES;
            return;
        }

        [allMessageAttachmentIds addObjectsFromArray:jobRecordAttachmentIds];

        [activeStickerFilePaths
            addObjectsFromArray:[StickerManager filePathsForAllInstalledStickersWithTransaction:transaction]];

        hasOrphanedPacksOrStickers = [StickerManager hasOrphanedDataWithTx:transaction];
    }];
    if (shouldAbort) {
        return nil;
    }

    NSMutableSet<NSString *> *orphanFilePaths = [allOnDiskFilePaths mutableCopy];
    [orphanFilePaths minusSet:allAttachmentFilePaths];
    [orphanFilePaths minusSet:profileAvatarFilePaths];
    [orphanFilePaths minusSet:groupAvatarFilePaths];
    [orphanFilePaths minusSet:activeStickerFilePaths];
    NSMutableSet<NSString *> *missingAttachmentFilePaths = [allAttachmentFilePaths mutableCopy];
    [missingAttachmentFilePaths minusSet:allOnDiskFilePaths];

    NSMutableSet<NSString *> *orphanAttachmentIds = [allAttachmentIds mutableCopy];
    [orphanAttachmentIds minusSet:allMessageAttachmentIds];
    [orphanAttachmentIds minusSet:allStoryAttachmentIds];
    NSMutableSet<NSString *> *missingAttachmentIds = [allMessageAttachmentIds mutableCopy];
    [missingAttachmentIds minusSet:allAttachmentIds];

    NSMutableSet<NSString *> *orphanReactionIds = [allReactionIds mutableCopy];
    [orphanReactionIds minusSet:allMessageReactionIds];
    NSMutableSet<NSString *> *missingReactionIds = [allMessageReactionIds mutableCopy];
    [missingReactionIds minusSet:allReactionIds];

    NSMutableSet<NSString *> *orphanMentionIds = [allMentionIds mutableCopy];
    [orphanMentionIds minusSet:allMessageMentionIds];
    NSMutableSet<NSString *> *missingMentionIds = [allMessageMentionIds mutableCopy];
    [missingMentionIds minusSet:allMentionIds];

    NSMutableSet<NSString *> *orphanFileAndDirectoryPaths = [NSMutableSet set];
    [orphanFileAndDirectoryPaths unionSet:voiceMessageDraftOrphanedPaths];
    [orphanFileAndDirectoryPaths unionSet:wallpaperOrphanedPaths];

    return [[OWSOrphanData alloc] initWithInteractionIds:[orphanInteractionIds copy]
                                           attachmentIds:[orphanAttachmentIds copy]
                                               filePaths:[orphanFilePaths copy]
                                             reactionIds:[orphanReactionIds copy]
                                              mentionIds:[orphanMentionIds copy]
                                   fileAndDirectoryPaths:[orphanFileAndDirectoryPaths copy]
                              hasOrphanedPacksOrStickers:hasOrphanedPacksOrStickers];
}

+ (void)auditAndCleanup:(BOOL)shouldRemoveOrphans
{
    [self auditAndCleanup:shouldRemoveOrphans completion:^ {}];
}


+ (void)auditAndCleanup:(BOOL)shouldRemoveOrphans completion:(nullable dispatch_block_t)completion
{
    OWSAssertIsOnMainThread();

    if (!AppReadiness.isAppReady) {
        OWSFailDebug(@"can't audit orphan data until app is ready.");
        return;
    }
    if (!CurrentAppContext().isMainApp) {
        OWSFailDebug(@"can't audit orphan data in app extensions.");
        return;
    }

    if (shouldRemoveOrphans) {
        OWSLogInfo(@"Starting orphan data cleanup");
    } else {
        OWSLogInfo(@"Starting orphan data audit");
    }

    // Orphan cleanup has two risks:
    //
    // * As a long-running process that involves access to the
    //   shared data container, it could cause 0xdead10cc.
    // * It could accidentally delete data still in use,
    //   e.g. a profile avatar which has been saved to disk
    //   but whose OWSUserProfile hasn't been saved yet.
    //
    // To prevent 0xdead10cc, the cleaner continually checks
    // whether the app has resigned active.  If so, it aborts.
    // Each phase (search, re-search, processing) retries N times,
    // then gives up until the next app launch.
    //
    // To prevent accidental data deletion, we take the following
    // measures:
    //
    // * Only cleanup data of the following types (which should
    //   include all relevant app data): profile avatar,
    //   attachment, temporary files (including temporary
    //   attachments).
    // * We don't delete any data created more recently than N seconds
    //   _before_ when the app launched.  This prevents any stray data
    //   currently in use by the app from being accidentally cleaned
    //   up.
    const NSInteger kMaxRetries = 3;
    [self findOrphanDataWithRetries:kMaxRetries
        success:^(OWSOrphanData *orphanData) {
            [self processOrphans:orphanData
                remainingRetries:kMaxRetries
                shouldRemoveOrphans:shouldRemoveOrphans
                success:^{
                    OWSLogInfo(@"Completed orphan data cleanup.");

                    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
                        [self.keyValueStore setString:AppVersion.shared.currentAppVersion
                                                  key:OWSOrphanDataCleaner_LastCleaningVersionKey
                                          transaction:transaction];

                        [self.keyValueStore setDate:[NSDate new]
                                                key:OWSOrphanDataCleaner_LastCleaningDateKey
                                        transaction:transaction];
                    });

                    if (completion) {
                        completion();
                    }
                }
                failure:^{
                    OWSLogInfo(@"Aborting orphan data cleanup.");
                    if (completion) {
                        completion();
                    }
                }];
        }
        failure:^{
            OWSLogInfo(@"Aborting orphan data cleanup.");
            if (completion) {
                completion();
            }
        }];
}

@end

NS_ASSUME_NONNULL_END
