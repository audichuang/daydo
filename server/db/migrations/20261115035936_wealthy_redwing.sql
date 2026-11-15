CREATE TABLE `projectInvite` (
	`id` text PRIMARY KEY NOT NULL,
	`projectId` text NOT NULL,
	`email` text NOT NULL,
	`role` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	`ownerUserId` text NOT NULL,
	`clocks` text DEFAULT '{}' NOT NULL,
	`serverSeq` integer NOT NULL,
	`purgedAt` integer
);
--> statement-breakpoint
CREATE INDEX `projectInvite_serverSeq_idx` ON `projectInvite` (`serverSeq`);--> statement-breakpoint
CREATE INDEX `projectInvite_ownerUserId_idx` ON `projectInvite` (`ownerUserId`);--> statement-breakpoint
CREATE INDEX `projectInvite_projectId_idx` ON `projectInvite` (`projectId`);