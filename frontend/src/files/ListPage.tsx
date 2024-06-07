import * as React from 'react';
import {
  Datagrid,
  List,
  FunctionField,
  useTranslate
} from 'react-admin';
import { useLocation } from "react-router-dom";
import {
  Box,
  Typography,
  Link,
  Card,
  CardContent
} from '@mui/material';
import { FaRegFolder, FaFile } from "react-icons/fa";

const humanFileSize = (bytes: any, si = false, dp = 1) => {
  const thresh = si ? 1000 : 1024;
  if (Math.abs(bytes) < thresh) {
    return bytes + ' B';
  }
  const units = si
    ? ['kB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB']
    : ['KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB', 'ZiB', 'YiB'];
  let u = -1;
  const r = 10 ** dp;
  do {
    bytes /= thresh;
    ++u;
  } while (Math.round(Math.abs(bytes) * r) / r >= thresh && u < units.length - 1);
  return bytes.toFixed(dp) + ' ' + units[u];
}

const PathBreadcrumb = () => {
  const location = useLocation();
  const path = location.pathname;
  const paths = path.split("/").filter(Boolean);
  let currentPath = "/";
  return <Box sx={{ display: "flex", flexWrap: "wrap", alignItems: "center", width: 1 }}>
    {paths.map((p, i) => {
      currentPath += p + "/";
      return <Box key={i} sx={{ display: "flex" }}>
        <Link href={`./#${currentPath}`} underline="hover" variant="body2">
          {p}
        </Link>
        <Typography variant="body2" sx={{ px: 1 }}>
          /
        </Typography>
      </Box>
    })}
  </Box>
}
const EmptyPage = () => {
  const translate = useTranslate();
  return (
    <Box sx={{ width: 1 }}>
      <PathBreadcrumb />
      <Card sx={{ width: 1 }}>
        <CardContent sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
          <Typography variant="body1">
            {translate("files.empty")}
          </Typography>
        </CardContent>
      </Card>
    </Box>
  )
}
const ClientList = () => {
  const translate = useTranslate();
  const location = useLocation();
  const path = location.pathname;
  return (
    <List
      resource="files"
      title={translate("files.title")}
      actions={<PathBreadcrumb />}
      queryOptions={{ meta: { path: path } }}
      empty={<EmptyPage />}
      sx={{ mt: 2 }}
    >
      <Datagrid bulkActionButtons={false}>
        <FunctionField source="name" label={"files.fields.name"} render={(record: any) => {
          if (record.is_dir) {
            return <Box sx={{ display: "flex" }}>
              <FaRegFolder />
              <Link href={`./#${path}${record.name}/`} underline="hover" variant="body2" sx={{ pl: 1 }}>
                {record.name}
              </Link>
            </Box>
          } else {
            return <Box sx={{ display: "flex" }}>
              <FaFile />
              <Typography variant="body2" sx={{ pl: 1 }}>
                {record.name}
              </Typography>
            </Box>
          }
        }} />
        <FunctionField source="size" label={"files.fields.size"} render={(record: any) => {
          if (record.is_dir) {
            return "-"
          } else {
            return humanFileSize(record.size)
          }
        }} />
      </Datagrid>
    </List>
  )
};

export default ClientList;