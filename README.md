# Refactored source layout

This package separates the code into two app folders so it is easier to upload to GitHub and assign files to different Xcode targets.

## Apps

- `AR-Navigation-App/` → end-user navigation app
- `Record-Route-Database-App/` → manager recording + database app

## Notes

- `GoogleService-Info.plist` is intentionally not included.
- Each app now has its own AppDelegate class name to avoid collisions:
  - `ARNavigationAppDelegate`
  - `RecordRouteAppDelegate`
- The main root views were renamed to avoid confusion:
  - `ARNavigationHomeView`
  - `RecordRouteHomeView`
- Files were split mainly by feature area to keep logic unchanged as much as possible.

## Recommended Xcode target membership

### AR-Navigation-App target
Add every `.swift` file inside `AR-Navigation-App/` to the AR navigation target.

### Record-Route-Database-App target
Add every `.swift` file inside `Record-Route-Database-App/` to the route-recording/database target.

## Important

This environment cannot run Xcode/iOS builds, so the refactor was done as a source split and naming cleanup rather than a compiled verification pass.
Before pushing to GitHub, open the project in Xcode and verify target membership, signing, Firebase plist placement, and Info.plist permissions.
