CREATE TABLE `attachment` (
	`id` text PRIMARY KEY NOT NULL,
	`taskId` text NOT NULL,
	`fileName` text NOT NULL,
	`size` integer NOT NULL,
	`mimeType` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `attachment_serverSeq_idx` ON `attachment` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `attachment_ownerUserId_idx` ON `attachment` (`ownerUserId`);--> statement-breakpoint
CREATE INDEX `attachment_taskId_idx` ON `attachment` (`taskId`);--> statement-breakpoint
CREATE TABLE `checklistItem` (
	`id` text PRIMARY KEY NOT NULL,
	`taskId` text NOT NULL,
	`title` text NOT NULL,
	`status` integer DEFAULT 0 NOT NULL,
	`sortKey` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `checklistItem_serverSeq_idx` ON `checklistItem` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `checklistItem_ownerUserId_idx` ON `checklistItem` (`ownerUserId`);--> statement-breakpoint
CREATE INDEX `checklistItem_taskId_idx` ON `checklistItem` (`taskId`);--> statement-breakpoint
CREATE TABLE `comment` (
	`id` text PRIMARY KEY NOT NULL,
	`taskId` text NOT NULL,
	`authorId` text NOT NULL,
	`body` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `comment_serverSeq_idx` ON `comment` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `comment_ownerUserId_idx` ON `comment` (`ownerUserId`);--> statement-breakpoint
CREATE INDEX `comment_taskId_idx` ON `comment` (`taskId`);--> statement-breakpoint
CREATE TABLE `device` (
	`id` text PRIMARY KEY NOT NULL,
	`userId` text NOT NULL,
	`lastSeenAt` integer NOT NULL,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `device_userId_idx` ON `device` (`userId`);--> statement-breakpoint
CREATE TABLE `folder` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`sortKey` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `folder_serverSeq_idx` ON `folder` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `folder_ownerUserId_idx` ON `folder` (`ownerUserId`);--> statement-breakpoint
CREATE TABLE `identity` (
	`provider` text NOT NULL,
	`sub` text NOT NULL,
	`userId` text NOT NULL,
	`email` text,
	PRIMARY KEY(`provider`, `sub`),
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `identity_userId_idx` ON `identity` (`userId`);--> statement-breakpoint
CREATE TABLE `member` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`initial` text NOT NULL,
	`color` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `member_serverSeq_idx` ON `member` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `member_ownerUserId_idx` ON `member` (`ownerUserId`);--> statement-breakpoint
CREATE TABLE `op_applied` (
	`opId` text PRIMARY KEY NOT NULL,
	`userId` text NOT NULL,
	`status` text NOT NULL,
	`serverSeq` integer NOT NULL,
	`createdAt` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `op_applied_userId_idx` ON `op_applied` (`userId`);--> statement-breakpoint
CREATE TABLE `project` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`color` text,
	`icon` text,
	`folderId` text,
	`viewMode` text DEFAULT 'list' NOT NULL,
	`kind` text DEFAULT 'TASK' NOT NULL,
	`isInbox` integer DEFAULT 0 NOT NULL,
	`ownerId` text NOT NULL,
	`sortKey` text NOT NULL,
	`showInSmart` text DEFAULT 'all' NOT NULL,
	`notifyMode` text DEFAULT 'all' NOT NULL,
	`archivedAt` integer,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `project_serverSeq_idx` ON `project` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `project_ownerUserId_idx` ON `project` (`ownerUserId`);--> statement-breakpoint
CREATE TABLE `projectMember` (
	`projectId` text NOT NULL,
	`memberId` text NOT NULL,
	`role` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer,
	PRIMARY KEY(`projectId`, `memberId`)
);
--> statement-breakpoint
CREATE INDEX `projectMember_serverSeq_idx` ON `projectMember` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `projectMember_ownerUserId_idx` ON `projectMember` (`ownerUserId`);--> statement-breakpoint
CREATE TABLE `seq` (
	`id` integer PRIMARY KEY NOT NULL,
	`value` integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE `session` (
	`id` text PRIMARY KEY NOT NULL,
	`userId` text NOT NULL,
	`deviceId` text NOT NULL,
	`chainId` text NOT NULL,
	`refreshHash` text NOT NULL,
	`expiresAt` integer NOT NULL,
	`createdAt` integer NOT NULL,
	`revokedAt` integer,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `session_refreshHash_unique` ON `session` (`refreshHash`);--> statement-breakpoint
CREATE INDEX `session_userId_idx` ON `session` (`userId`);--> statement-breakpoint
CREATE INDEX `session_chainId_idx` ON `session` (`chainId`);--> statement-breakpoint
CREATE TABLE `tag` (
	`name` text NOT NULL,
	`label` text NOT NULL,
	`color` text,
	`sortKey` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer,
	PRIMARY KEY(`ownerUserId`, `name`)
);
--> statement-breakpoint
CREATE INDEX `tag_serverSeq_idx` ON `tag` (`serverSeq`);--> statement-breakpoint
CREATE TABLE `task` (
	`id` text PRIMARY KEY NOT NULL,
	`projectId` text NOT NULL,
	`title` text NOT NULL,
	`content` text DEFAULT '' NOT NULL,
	`priority` integer DEFAULT 0 NOT NULL,
	`status` integer DEFAULT 0 NOT NULL,
	`startDay` text,
	`startMinute` integer,
	`endDay` text,
	`endMinute` integer,
	`timeZone` text,
	`reminders` text DEFAULT '[]' NOT NULL,
	`repeatRule` text,
	`tags` text DEFAULT '[]' NOT NULL,
	`assigneeId` text,
	`sortKey` text NOT NULL,
	`completedAt` integer,
	`sourceRaw` text,
	`importNote` text,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `task_serverSeq_idx` ON `task` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `task_ownerUserId_idx` ON `task` (`ownerUserId`);--> statement-breakpoint
CREATE INDEX `task_projectId_idx` ON `task` (`projectId`);--> statement-breakpoint
CREATE TABLE `user` (
	`id` text PRIMARY KEY NOT NULL,
	`createdAt` integer NOT NULL
);
