import * as React from 'react';
import {
  AppBar,
  TitlePortal,
  useTranslate,
} from 'react-admin';
import {
  Switch,
  Chip,
  Box,
  Typography,
} from '@mui/material';
import { IsAdminContext } from '../isAdminContext';
import { getServiceStatus, ServiceStatus } from '../serviceStatus';

const SwitchButton = () => {
  const { isAdmin, adminMode, setAdminMode } = React.useContext(IsAdminContext);
  const translate = useTranslate();
  const handleChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    setAdminMode(event.target.checked);
  };
  if (!isAdmin) return null
  return (<Box sx={{ display: "inline-flex", mr: 2 }}>
    <Typography sx={{ pt: 1 }}>{translate("other.changeMode")}</Typography>
    <Switch
      checked={adminMode}
      onChange={handleChange}
    />
  </Box>

  )
};

const ServiceStatusBadge = () => {
  const translate = useTranslate();
  const [status, setStatus] = React.useState<ServiceStatus>("stopped");
  const [loading, setLoading] = React.useState(true);

  const updateStatus = React.useCallback(async () => {
    const nextStatus = await getServiceStatus();
    setStatus(nextStatus);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    updateStatus();
    const timer = window.setInterval(updateStatus, 15000);
    return () => window.clearInterval(timer);
  }, [updateStatus]);

  let label = translate("other.serviceStatusStopped");
  if (loading) label = translate("other.serviceStatusLoading");
  if (!loading && status === "running") label = translate("other.serviceStatusRunning");

  return (
    <Chip
      size="small"
      color={status === "running" ? "success" : "default"}
      variant={status === "running" ? "filled" : "outlined"}
      label={label}
      sx={{ mr: 2, mt: 1 }}
    />
  );
};

const MyAppBar = () => (
  <AppBar>
    <TitlePortal />
    <ServiceStatusBadge />
    <SwitchButton />
  </AppBar>
);

export default MyAppBar;
