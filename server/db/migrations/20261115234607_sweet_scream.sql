CREATE TABLE `icsMapping` (
	`sourceId` integer NOT NULL,
	`icsUid` text NOT NULL,
	`occurrenceId` text NOT NULL,
	`taskId` text NOT NULL,
	`projectId` text NOT NULL,
	`fingerprint` text,
	`sequence` integer,
	`dtstamp` text,
	`state` text NOT NULL,
	`seriesSignature` text,
	`lastError` text,
	`updatedAt` integer NOT NULL,
	PRIMARY KEY(`sourceId`, `icsUid`, `occurrenceId`)
);
--> statement-breakpoint
CREATE INDEX `icsMapping_sourceId_idx` ON `icsMapping` (`sourceId`);--> statement-breakpoint
CREATE TABLE `icsSource` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`userId` text NOT NULL,
	`name` text NOT NULL,
	`url` text NOT NULL,
	`projectId` text NOT NULL,
	`enabled` integer DEFAULT 1 NOT NULL,
	`syncIntervalSec` integer DEFAULT 900 NOT NULL,
	`filterJson` text,
	`timezone` text,
	`lastSyncAt` integer,
	`lastStatus` text,
	`lastStats` text,
	`leaseToken` text,
	`leaseUntilMs` integer,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `icsSource_userId_idx` ON `icsSource` (`userId`);--> statement-breakpoint
CREATE TABLE `oauthClient` (
	`clientId` text PRIMARY KEY NOT NULL,
	`clientName` text NOT NULL,
	`redirectUris` text NOT NULL,
	`ipHash` text NOT NULL,
	`createdAt` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `oauthClient_ipHash_createdAt_idx` ON `oauthClient` (`ipHash`,`createdAt`);--> statement-breakpoint
CREATE TABLE `oauthCode` (
	`codeHash` text PRIMARY KEY NOT NULL,
	`clientId` text NOT NULL,
	`redirectUri` text NOT NULL,
	`codeChallenge` text NOT NULL,
	`scope` text NOT NULL,
	`resource` text,
	`userId` text NOT NULL,
	`familyId` text NOT NULL,
	`expiresAt` integer NOT NULL,
	`usedAt` integer
);
--> statement-breakpoint
CREATE TABLE `oauthPending` (
	`id` text PRIMARY KEY NOT NULL,
	`clientId` text NOT NULL,
	`redirectUri` text NOT NULL,
	`codeChallenge` text NOT NULL,
	`scope` text NOT NULL,
	`clientState` text,
	`resource` text,
	`bindHash` text NOT NULL,
	`provider` text NOT NULL,
	`nonce` text NOT NULL,
	`userId` text,
	`consentTokenHash` text,
	`createdAt` integer NOT NULL,
	`expiresAt` integer NOT NULL,
	`consumedAt` integer
);
--> statement-breakpoint
CREATE TABLE `oauthRefresh` (
	`refreshHash` text PRIMARY KEY NOT NULL,
	`familyId` text NOT NULL,
	`userId` text NOT NULL,
	`clientId` text NOT NULL,
	`scope` text NOT NULL,
	`resource` text,
	`createdAt` integer NOT NULL,
	`expiresAt` integer NOT NULL,
	`revokedAt` integer,
	`replacedBy` text
);
--> statement-breakpoint
CREATE INDEX `oauthRefresh_familyId_idx` ON `oauthRefresh` (`familyId`);