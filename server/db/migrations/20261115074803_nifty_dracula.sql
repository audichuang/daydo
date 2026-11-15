CREATE TABLE `invite` (
	`codeHash` text PRIMARY KEY NOT NULL,
	`projectId` text NOT NULL,
	`role` text NOT NULL,
	`email` text,
	`createdBy` text NOT NULL,
	`createdAt` integer NOT NULL,
	`expiresAt` integer NOT NULL,
	`revokedAt` integer
);
--> statement-breakpoint
CREATE INDEX `invite_projectId_idx` ON `invite` (`projectId`);--> statement-breakpoint
ALTER TABLE `user` ADD `name` text;--> statement-breakpoint
ALTER TABLE `user` ADD `initial` text;--> statement-breakpoint
ALTER TABLE `user` ADD `color` text;