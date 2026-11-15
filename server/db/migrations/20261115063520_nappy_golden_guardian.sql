-- void:allow-destructive
CREATE TABLE `entityHome` (
	`entity` text NOT NULL,
	`entityId` text NOT NULL,
	`scope` text NOT NULL,
	PRIMARY KEY(`entity`, `entityId`)
);
--> statement-breakpoint
CREATE TABLE `listScopes` (
	`projectId` text NOT NULL,
	`scope` text NOT NULL,
	PRIMARY KEY(`projectId`, `scope`)
);
--> statement-breakpoint
CREATE INDEX `listScopes_scope_idx` ON `listScopes` (`scope`);--> statement-breakpoint
CREATE TABLE `projectMembership` (
	`projectId` text NOT NULL,
	`userId` text NOT NULL,
	`role` text NOT NULL,
	`createdAt` integer NOT NULL,
	`removedAt` integer,
	PRIMARY KEY(`projectId`, `userId`)
);
--> statement-breakpoint
CREATE INDEX `projectMembership_userId_idx` ON `projectMembership` (`userId`);--> statement-breakpoint
CREATE TABLE `purgedProject` (
	`projectId` text PRIMARY KEY NOT NULL,
	`purgedAt` integer NOT NULL
);
--> statement-breakpoint
DROP TABLE `attachment`;--> statement-breakpoint
DROP TABLE `checklistItem`;--> statement-breakpoint
DROP TABLE `comment`;--> statement-breakpoint
DROP TABLE `folder`;--> statement-breakpoint
DROP TABLE `member`;--> statement-breakpoint
DROP TABLE `op_applied`;--> statement-breakpoint
DROP TABLE `project`;--> statement-breakpoint
DROP TABLE `projectInvite`;--> statement-breakpoint
DROP TABLE `projectMember`;--> statement-breakpoint
DROP TABLE `seq`;--> statement-breakpoint
DROP TABLE `tag`;--> statement-breakpoint
DROP TABLE `task`;